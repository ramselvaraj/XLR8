// SPDX-License-Identifier: GPL-2.0
/*
 * XLR8 V4L2 memory-to-memory device: /dev/videoN takes a 64x64 image on the OUTPUT queue, blurs
 * it on the GPU, and returns the result on the CAPTURE queue.
 *
 * The GPU reads the OUTPUT buffer and writes the CAPTURE buffer directly in DDR. Its memory
 * window starts at the lower of the two buffers and covers both; the source and destination are
 * handed to the kernel as word offsets from that base. Each job loads its own program, so it
 * cannot be disturbed by /dev/xlr8 clients, and shares the GPU with them through the same claim.
 */
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/workqueue.h>

#include <media/v4l2-device.h>
#include <media/v4l2-event.h>
#include <media/v4l2-ioctl.h>
#include <media/v4l2-mem2mem.h>
#include <media/videobuf2-dma-contig.h>

#include "xlr8_blur_fw.h"
#include "xlr8_priv.h"

#define XV_NAME     "xlr8"
#define XV_W        64
#define XV_H        64
#define XV_BPL      (XV_W * 4)
#define XV_IMGSIZE  (XV_BPL * XV_H)
/* Memory order B, G, R, X: a little-endian 0x00RRGGBB word, as the GPU kernels use. */
#define XV_FORMAT   V4L2_PIX_FMT_XBGR32

struct xv_dev {
	struct v4l2_device v4l2_dev;
	struct video_device vfd;
	struct v4l2_m2m_dev *m2m;
	struct mutex lock;
	struct xlr8_dev *gpu;
	struct workqueue_struct *wq;
};

struct xv_ctx {
	struct v4l2_fh fh;
	struct xv_dev *xv;
	struct v4l2_m2m_ctx *m2m_ctx;
	struct work_struct work;
	u32 seq;
};

static struct xv_dev *g_xv;

static inline struct xv_ctx *fh_to_ctx(struct v4l2_fh *fh)
{
	return container_of(fh, struct xv_ctx, fh);
}

/* ---------------------------------------------------------------- the job */

static void xv_job_work(struct work_struct *w)
{
	struct xv_ctx *ctx = container_of(w, struct xv_ctx, work);
	struct xv_dev *xv = ctx->xv;
	struct vb2_v4l2_buffer *src, *dst;
	struct xlr8_kjob job = { 0 };
	dma_addr_t in, out, base, end;
	enum vb2_buffer_state state;
	int ret;

	src = v4l2_m2m_next_src_buf(ctx->m2m_ctx);
	dst = v4l2_m2m_next_dst_buf(ctx->m2m_ctx);
	in = vb2_dma_contig_plane_dma_addr(&src->vb2_buf, 0);
	out = vb2_dma_contig_plane_dma_addr(&dst->vb2_buf, 0);
	base = min(in, out);
	end = max(in, out) + XV_IMGSIZE;

	job.prog = xlr8_blur64_prog;
	job.nprog = XLR8_BLUR64_NPROG;
	job.npass = 2;
	job.pass[0].threads = XLR8_BLUR64_THREADS1;
	job.pass[0].prog_base = 0;
	job.pass[1].threads = XLR8_BLUR64_THREADS2;
	job.pass[1].prog_base = XLR8_BLUR64_BASE2;
	job.mbase = lower_32_bits(base);
	job.mlim = lower_32_bits(end - base);
	job.src = (in - base) / 4;
	job.dst = (out - base) / 4;

	ret = xlr8_kjob_run(xv->gpu, &job);
	state = ret ? VB2_BUF_STATE_ERROR : VB2_BUF_STATE_DONE;
	if (ret)
		dev_warn(xlr8_dev_device(xv->gpu), "v4l2 blur job failed: %d\n", ret);

	src = v4l2_m2m_src_buf_remove(ctx->m2m_ctx);
	dst = v4l2_m2m_dst_buf_remove(ctx->m2m_ctx);
	dst->sequence = ctx->seq++;
	v4l2_m2m_buf_copy_metadata(src, dst, true);
	if (!ret)
		vb2_set_plane_payload(&dst->vb2_buf, 0, XV_IMGSIZE);
	v4l2_m2m_buf_done(src, state);
	v4l2_m2m_buf_done(dst, state);
	v4l2_m2m_job_finish(xv->m2m, ctx->m2m_ctx);
}

static void xv_device_run(void *priv)
{
	struct xv_ctx *ctx = priv;

	queue_work(ctx->xv->wq, &ctx->work);
}

static void xv_job_abort(void *priv)
{
	/* nothing to cancel: a running job finishes within a frame time and calls job_finish */
}

static const struct v4l2_m2m_ops xv_m2m_ops = {
	.device_run = xv_device_run,
	.job_abort = xv_job_abort,
};

/* ---------------------------------------------------------------- vb2 queues */

static int xv_queue_setup(struct vb2_queue *vq, unsigned int *nbuffers, unsigned int *nplanes,
			  unsigned int sizes[], struct device *alloc_devs[])
{
	if (*nplanes)
		return sizes[0] < XV_IMGSIZE ? -EINVAL : 0;
	*nplanes = 1;
	sizes[0] = XV_IMGSIZE;
	return 0;
}

static int xv_buf_prepare(struct vb2_buffer *vb)
{
	if (vb2_plane_size(vb, 0) < XV_IMGSIZE)
		return -EINVAL;
	if (V4L2_TYPE_IS_OUTPUT(vb->vb2_queue->type))
		vb2_set_plane_payload(vb, 0, XV_IMGSIZE);
	return 0;
}

static void xv_buf_queue(struct vb2_buffer *vb)
{
	struct vb2_v4l2_buffer *vbuf = to_vb2_v4l2_buffer(vb);
	struct xv_ctx *ctx = vb2_get_drv_priv(vb->vb2_queue);

	v4l2_m2m_buf_queue(ctx->m2m_ctx, vbuf);
}

static int xv_start_streaming(struct vb2_queue *q, unsigned int count)
{
	struct xv_ctx *ctx = vb2_get_drv_priv(q);

	if (!V4L2_TYPE_IS_OUTPUT(q->type))
		ctx->seq = 0;
	return 0;
}

static void xv_stop_streaming(struct vb2_queue *q)
{
	struct xv_ctx *ctx = vb2_get_drv_priv(q);
	struct vb2_v4l2_buffer *vbuf;

	for (;;) {
		vbuf = V4L2_TYPE_IS_OUTPUT(q->type) ? v4l2_m2m_src_buf_remove(ctx->m2m_ctx)
						    : v4l2_m2m_dst_buf_remove(ctx->m2m_ctx);
		if (!vbuf)
			break;
		v4l2_m2m_buf_done(vbuf, VB2_BUF_STATE_ERROR);
	}
}

static const struct vb2_ops xv_qops = {
	.queue_setup     = xv_queue_setup,
	.buf_prepare     = xv_buf_prepare,
	.buf_queue       = xv_buf_queue,
	.start_streaming = xv_start_streaming,
	.stop_streaming  = xv_stop_streaming,
	.wait_prepare    = vb2_ops_wait_prepare,
	.wait_finish     = vb2_ops_wait_finish,
};

static int xv_queue_init(void *priv, struct vb2_queue *src_vq, struct vb2_queue *dst_vq)
{
	struct xv_ctx *ctx = priv;
	int ret;

	src_vq->type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	src_vq->io_modes = VB2_MMAP | VB2_DMABUF;
	src_vq->drv_priv = ctx;
	src_vq->ops = &xv_qops;
	src_vq->mem_ops = &vb2_dma_contig_memops;
	src_vq->buf_struct_size = sizeof(struct v4l2_m2m_buffer);
	src_vq->timestamp_flags = V4L2_BUF_FLAG_TIMESTAMP_COPY;
	src_vq->lock = &ctx->xv->lock;
	src_vq->dev = xlr8_dev_device(ctx->xv->gpu);
	ret = vb2_queue_init(src_vq);
	if (ret)
		return ret;

	dst_vq->type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	dst_vq->io_modes = VB2_MMAP | VB2_DMABUF;
	dst_vq->drv_priv = ctx;
	dst_vq->ops = &xv_qops;
	dst_vq->mem_ops = &vb2_dma_contig_memops;
	dst_vq->buf_struct_size = sizeof(struct v4l2_m2m_buffer);
	dst_vq->timestamp_flags = V4L2_BUF_FLAG_TIMESTAMP_COPY;
	dst_vq->lock = &ctx->xv->lock;
	dst_vq->dev = xlr8_dev_device(ctx->xv->gpu);
	return vb2_queue_init(dst_vq);
}

/* ---------------------------------------------------------------- ioctls */

static int xv_querycap(struct file *file, void *priv, struct v4l2_capability *cap)
{
	strscpy(cap->driver, XV_NAME, sizeof(cap->driver));
	strscpy(cap->card, "XLR8 GPU 3x3 blur", sizeof(cap->card));
	strscpy(cap->bus_info, "platform:xlr8", sizeof(cap->bus_info));
	return 0;
}

static int xv_enum_fmt(struct file *file, void *priv, struct v4l2_fmtdesc *f)
{
	if (f->index)
		return -EINVAL;
	f->pixelformat = XV_FORMAT;
	return 0;
}

static void xv_fill_fmt(struct v4l2_format *f)
{
	f->fmt.pix.width = XV_W;
	f->fmt.pix.height = XV_H;
	f->fmt.pix.pixelformat = XV_FORMAT;
	f->fmt.pix.field = V4L2_FIELD_NONE;
	f->fmt.pix.bytesperline = XV_BPL;
	f->fmt.pix.sizeimage = XV_IMGSIZE;
	f->fmt.pix.colorspace = V4L2_COLORSPACE_SRGB;
	f->fmt.pix.xfer_func = V4L2_XFER_FUNC_DEFAULT;
	f->fmt.pix.ycbcr_enc = V4L2_YCBCR_ENC_DEFAULT;
	f->fmt.pix.quantization = V4L2_QUANTIZATION_DEFAULT;
}

/* One fixed format on both queues: the hardware kernel is generated for 64x64. */
static int xv_fmt(struct file *file, void *priv, struct v4l2_format *f)
{
	xv_fill_fmt(f);
	return 0;
}

static int xv_enum_framesizes(struct file *file, void *priv, struct v4l2_frmsizeenum *fsize)
{
	if (fsize->index || fsize->pixel_format != XV_FORMAT)
		return -EINVAL;
	fsize->type = V4L2_FRMSIZE_TYPE_DISCRETE;
	fsize->discrete.width = XV_W;
	fsize->discrete.height = XV_H;
	return 0;
}

static const struct v4l2_ioctl_ops xv_ioctl_ops = {
	.vidioc_querycap          = xv_querycap,
	.vidioc_enum_fmt_vid_cap  = xv_enum_fmt,
	.vidioc_enum_fmt_vid_out  = xv_enum_fmt,
	.vidioc_g_fmt_vid_cap     = xv_fmt,
	.vidioc_try_fmt_vid_cap   = xv_fmt,
	.vidioc_s_fmt_vid_cap     = xv_fmt,
	.vidioc_g_fmt_vid_out     = xv_fmt,
	.vidioc_try_fmt_vid_out   = xv_fmt,
	.vidioc_s_fmt_vid_out     = xv_fmt,
	.vidioc_enum_framesizes   = xv_enum_framesizes,
	.vidioc_reqbufs           = v4l2_m2m_ioctl_reqbufs,
	.vidioc_querybuf          = v4l2_m2m_ioctl_querybuf,
	.vidioc_qbuf              = v4l2_m2m_ioctl_qbuf,
	.vidioc_dqbuf             = v4l2_m2m_ioctl_dqbuf,
	.vidioc_prepare_buf       = v4l2_m2m_ioctl_prepare_buf,
	.vidioc_create_bufs       = v4l2_m2m_ioctl_create_bufs,
	.vidioc_expbuf            = v4l2_m2m_ioctl_expbuf,
	.vidioc_streamon          = v4l2_m2m_ioctl_streamon,
	.vidioc_streamoff         = v4l2_m2m_ioctl_streamoff,
};

/* ---------------------------------------------------------------- file operations */

static int xv_open(struct file *file)
{
	struct xv_dev *xv = video_drvdata(file);
	struct xv_ctx *ctx;
	int ret = 0;

	ctx = kzalloc(sizeof(*ctx), GFP_KERNEL);
	if (!ctx)
		return -ENOMEM;
	if (mutex_lock_interruptible(&xv->lock)) {
		kfree(ctx);
		return -ERESTARTSYS;
	}
	ctx->xv = xv;
	INIT_WORK(&ctx->work, xv_job_work);
	v4l2_fh_init(&ctx->fh, video_devdata(file));
	file->private_data = &ctx->fh;
	ctx->m2m_ctx = v4l2_m2m_ctx_init(xv->m2m, ctx, xv_queue_init);
	if (IS_ERR(ctx->m2m_ctx)) {
		ret = PTR_ERR(ctx->m2m_ctx);
		v4l2_fh_exit(&ctx->fh);
		kfree(ctx);
	} else {
		ctx->fh.m2m_ctx = ctx->m2m_ctx;      /* the v4l2_m2m_ioctl_*() and fop helpers read it */
		v4l2_fh_add(&ctx->fh);
	}
	mutex_unlock(&xv->lock);
	return ret;
}

static int xv_release(struct file *file)
{
	struct xv_dev *xv = video_drvdata(file);
	struct xv_ctx *ctx = fh_to_ctx(file->private_data);

	mutex_lock(&xv->lock);
	v4l2_m2m_ctx_release(ctx->m2m_ctx);     /* waits for a running job */
	v4l2_fh_del(&ctx->fh);
	v4l2_fh_exit(&ctx->fh);
	mutex_unlock(&xv->lock);
	flush_work(&ctx->work);
	kfree(ctx);
	return 0;
}

static const struct v4l2_file_operations xv_fops = {
	.owner          = THIS_MODULE,
	.open           = xv_open,
	.release        = xv_release,
	.poll           = v4l2_m2m_fop_poll,
	.unlocked_ioctl = video_ioctl2,
	.mmap           = v4l2_m2m_fop_mmap,
};

/* ---------------------------------------------------------------- module */

static int __init xv_init(void)
{
	struct xv_dev *xv;
	int ret;

	xv = kzalloc(sizeof(*xv), GFP_KERNEL);
	if (!xv)
		return -ENOMEM;
	xv->gpu = xlr8_dev_get();
	if (!xv->gpu) {
		ret = -ENODEV;
		goto err_free;
	}
	mutex_init(&xv->lock);
	xv->wq = alloc_ordered_workqueue("xlr8_v4l2", 0);
	if (!xv->wq) {
		ret = -ENOMEM;
		goto err_put;
	}
	ret = v4l2_device_register(xlr8_dev_device(xv->gpu), &xv->v4l2_dev);
	if (ret)
		goto err_wq;
	xv->m2m = v4l2_m2m_init(&xv_m2m_ops);
	if (IS_ERR(xv->m2m)) {
		ret = PTR_ERR(xv->m2m);
		goto err_v4l2;
	}
	xv->vfd.fops = &xv_fops;
	xv->vfd.ioctl_ops = &xv_ioctl_ops;
	xv->vfd.release = video_device_release_empty;
	xv->vfd.vfl_dir = VFL_DIR_M2M;
	xv->vfd.device_caps = V4L2_CAP_VIDEO_M2M | V4L2_CAP_STREAMING;
	xv->vfd.lock = &xv->lock;
	xv->vfd.v4l2_dev = &xv->v4l2_dev;
	strscpy(xv->vfd.name, XV_NAME, sizeof(xv->vfd.name));
	video_set_drvdata(&xv->vfd, xv);
	ret = video_register_device(&xv->vfd, VFL_TYPE_VIDEO, -1);
	if (ret)
		goto err_m2m;
	g_xv = xv;
	dev_info(xlr8_dev_device(xv->gpu), "V4L2 blur device registered as /dev/video%d\n", xv->vfd.num);
	return 0;

err_m2m:
	v4l2_m2m_release(xv->m2m);
err_v4l2:
	v4l2_device_unregister(&xv->v4l2_dev);
err_wq:
	destroy_workqueue(xv->wq);
err_put:
	xlr8_dev_put(xv->gpu);
err_free:
	kfree(xv);
	return ret;
}

static void __exit xv_exit(void)
{
	struct xv_dev *xv = g_xv;

	video_unregister_device(&xv->vfd);
	v4l2_m2m_release(xv->m2m);
	v4l2_device_unregister(&xv->v4l2_dev);
	destroy_workqueue(xv->wq);
	xlr8_dev_put(xv->gpu);
	kfree(xv);
}

module_init(xv_init);
module_exit(xv_exit);

MODULE_DESCRIPTION("XLR8 V4L2 memory-to-memory blur device");
MODULE_AUTHOR("Ram Selvaraj");
MODULE_LICENSE("GPL");
