// SPDX-License-Identifier: GPL-2.0
/*
 * XLR8 GPU driver: platform driver exposing the XLR8 AXI accelerator as /dev/xlr8.
 *
 * Model: each open file may own one DMA buffer (the GPU's memory window). A job is
 * LOAD_PROG (once), SET_BUF + mmap, SUBMIT, WAIT. The device runs one job at a time; further
 * SUBMIT/LOAD_PROG calls sleep until it is free. Completion is interrupt driven. A watchdog
 * soft-resets a GPU that never finishes.
 */
#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/fs.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/poll.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/wait.h>
#include <linux/workqueue.h>

#include "xlr8_uapi.h"

#define DRV_NAME "xlr8"

/* register offsets */
#define R_CTRL       0x00
#define R_STATUS     0x04
#define R_THREADS    0x08
#define R_SRC        0x0c
#define R_DST        0x10
#define R_PROG       0x14
#define R_MBASE      0x18
#define R_MLIM       0x1c
#define R_IRQ        0x20
#define R_CYC        0x24
#define R_XACT       0x28
#define R_STALL      0x2c
#define R_ERRA       0x30
#define R_ID         0x34
#define R_VER        0x38
#define R_ARG0       0x3c   /* ARG0..ARG5, 4 bytes apart (hardware 0.2+) */
#define R_WIN        0x1000

#define CTRL_START   BIT(0)
#define CTRL_SOFT    BIT(1)
#define CTRL_IRQ_EN  BIT(2)
#define ST_BUSY      BIT(0)

#define AFI0_BASE    0xF8008000UL   /* Zynq-7000 S_AXI_HP0 interface registers */

static unsigned int job_timeout_ms = 3000;
module_param(job_timeout_ms, uint, 0644);
MODULE_PARM_DESC(job_timeout_ms, "watchdog: soft-reset a job running longer than this");

struct xlr8_dev;

struct xlr8_ctx {
	struct xlr8_dev *dev;
	void *buf;
	dma_addr_t dma;
	size_t size;
	/* job state, protected by dev->lock */
	bool submitted;
	bool done;
	struct xlr8_wait res;
	wait_queue_head_t wq;
};

struct xlr8_dev {
	struct device *dev;
	void __iomem *regs;
	struct clk *clk;
	int irq;
	struct miscdevice misc;

	spinlock_t lock;
	bool busy;              /* device claimed (job running, resetting, or program loading) */
	bool running;           /* a hardware job is in flight */
	struct xlr8_ctx *owner;
	wait_queue_head_t idle_wq;
	struct delayed_work wd;
	unsigned long irq_count;
	u32 hw_version;
};

static inline u32 rd(struct xlr8_dev *d, u32 off) { return ioread32(d->regs + off); }
static inline void wr(struct xlr8_dev *d, u32 off, u32 v) { iowrite32(v, d->regs + off); }

/* ---------------------------------------------------------------- claim / release */

static bool try_claim(struct xlr8_dev *d, struct xlr8_ctx *c)
{
	unsigned long fl;
	bool ok = false;

	spin_lock_irqsave(&d->lock, fl);
	if (!d->busy) {
		d->busy = true;
		d->owner = c;
		ok = true;
	}
	spin_unlock_irqrestore(&d->lock, fl);
	return ok;
}

static void release_dev(struct xlr8_dev *d)
{
	unsigned long fl;

	spin_lock_irqsave(&d->lock, fl);
	d->busy = false;
	d->running = false;
	d->owner = NULL;
	spin_unlock_irqrestore(&d->lock, fl);
	wake_up_interruptible_all(&d->idle_wq);
}

static void capture(struct xlr8_dev *d, struct xlr8_ctx *c, u32 extra)
{
	c->res.status = (rd(d, R_STATUS) & ~ST_BUSY) | extra;
	c->res.cycles = rd(d, R_CYC);
	c->res.xacts = rd(d, R_XACT);
	c->res.stalls = rd(d, R_STALL);
	c->res.err_addr = rd(d, R_ERRA);
}

/* Soft-reset the GPU and wait for the bridge to drain. Sleeps; call from process context. */
static void hw_soft_reset(struct xlr8_dev *d)
{
	int i;

	wr(d, R_CTRL, CTRL_SOFT);
	for (i = 0; i < 200; i++) {
		usleep_range(100, 200);
		if (!(rd(d, R_STATUS) & ST_BUSY))
			break;
	}
	if (i == 200)
		dev_err(d->dev, "GPU still busy after soft reset\n");
	wr(d, R_IRQ, 3);
}

/* Abort the job owned by `c` (watchdog, or the owner went away). */
static void abort_job(struct xlr8_dev *d, struct xlr8_ctx *c, u32 flag)
{
	unsigned long fl;
	bool was_running;

	spin_lock_irqsave(&d->lock, fl);
	was_running = d->running && d->owner == c;
	if (was_running)
		d->running = false;         /* stop the IRQ handler from also completing it */
	spin_unlock_irqrestore(&d->lock, fl);
	if (!was_running)
		return;

	hw_soft_reset(d);
	spin_lock_irqsave(&d->lock, fl);
	capture(d, c, flag);
	c->res.status |= flag;
	c->done = true;
	spin_unlock_irqrestore(&d->lock, fl);
	wake_up_interruptible_all(&c->wq);
	release_dev(d);
}

static void watchdog(struct work_struct *w)
{
	struct xlr8_dev *d = container_of(to_delayed_work(w), struct xlr8_dev, wd);
	struct xlr8_ctx *c;
	unsigned long fl;

	spin_lock_irqsave(&d->lock, fl);
	c = d->running ? d->owner : NULL;
	spin_unlock_irqrestore(&d->lock, fl);
	if (c) {
		dev_warn(d->dev, "job timed out after %u ms, resetting GPU\n", job_timeout_ms);
		abort_job(d, c, XLR8_ST_TIMEOUT);
	}
}

static irqreturn_t xlr8_irq(int irq, void *data)
{
	struct xlr8_dev *d = data;
	struct xlr8_ctx *c;
	u32 ist = rd(d, R_IRQ);

	if (!ist)
		return IRQ_NONE;
	wr(d, R_IRQ, ist);                  /* write 1 to clear */

	spin_lock(&d->lock);
	d->irq_count++;
	c = d->running ? d->owner : NULL;
	if (c) {
		cancel_delayed_work(&d->wd);        /* safe in IRQ context; a late fire is also harmless */
		d->running = false;
		capture(d, c, 0);
		c->done = true;
		d->busy = false;
		d->owner = NULL;
		wake_up_interruptible_all(&c->wq);
		wake_up_interruptible_all(&d->idle_wq);
	}
	spin_unlock(&d->lock);
	return IRQ_HANDLED;
}

/* ---------------------------------------------------------------- file operations */

static int xlr8_open(struct inode *inode, struct file *f)
{
	struct miscdevice *m = f->private_data;
	struct xlr8_dev *d = container_of(m, struct xlr8_dev, misc);
	struct xlr8_ctx *c = kzalloc(sizeof(*c), GFP_KERNEL);

	if (!c)
		return -ENOMEM;
	c->dev = d;
	init_waitqueue_head(&c->wq);
	f->private_data = c;
	return 0;
}

static void free_buf(struct xlr8_ctx *c)
{
	if (c->buf) {
		dma_free_coherent(c->dev->dev, c->size, c->buf, c->dma);
		c->buf = NULL;
		c->size = 0;
	}
}

static int xlr8_release(struct inode *inode, struct file *f)
{
	struct xlr8_ctx *c = f->private_data;
	struct xlr8_dev *d = c->dev;

	/* a job still running for a closed file: stop it before its buffer disappears */
	abort_job(d, c, XLR8_ST_ABORTED);
	/* if the owner is in the middle of completing, wait until the device lets go of the buffer */
	wait_event(d->idle_wq, ({ unsigned long fl; bool mine;
		spin_lock_irqsave(&d->lock, fl); mine = (d->owner == c); spin_unlock_irqrestore(&d->lock, fl);
		!mine; }));
	free_buf(c);
	kfree(c);
	return 0;
}

static int check_zero(const u32 *r, int n)
{
	while (n--)
		if (*r++)
			return -EINVAL;
	return 0;
}

static long do_info(struct xlr8_ctx *c, void __user *arg)
{
	struct xlr8_info i = {
		.uapi_version = XLR8_UAPI_VERSION,
		.id = rd(c->dev, R_ID),
		.hw_version = rd(c->dev, R_VER),
		.status = rd(c->dev, R_STATUS),
		.max_prog_instrs = XLR8_MAX_PROG,
		.buf_size = c->size,
	};

	return copy_to_user(arg, &i, sizeof(i)) ? -EFAULT : 0;
}

static long do_load_prog(struct xlr8_ctx *c, void __user *arg)
{
	struct xlr8_dev *d = c->dev;
	struct xlr8_prog p;
	u16 *ins;
	u32 w, n;
	long ret;

	if (copy_from_user(&p, arg, sizeof(p)))
		return -EFAULT;
	if (check_zero(p.reserved, ARRAY_SIZE(p.reserved)))
		return -EINVAL;
	if (!p.count || p.count > XLR8_MAX_PROG)
		return -EINVAL;
	ins = memdup_user(u64_to_user_ptr(p.instrs), p.count * sizeof(u16));
	if (IS_ERR(ins))
		return PTR_ERR(ins);

	ret = wait_event_interruptible(d->idle_wq, try_claim(d, c));
	if (ret) {
		kfree(ins);
		return ret;
	}
	n = (p.count + 1) / 2;
	for (w = 0; w < n; w++) {
		u32 lo = ins[2 * w];
		u32 hi = (2 * w + 1 < p.count) ? ins[2 * w + 1] : 0;

		wr(d, R_WIN + 4 * w, (hi << 16) | lo);
	}
	for (w = 0; w < n; w++) {           /* read back what the GPU will fetch */
		u32 lo = ins[2 * w];
		u32 hi = (2 * w + 1 < p.count) ? ins[2 * w + 1] : 0;

		if (rd(d, R_WIN + 4 * w) != ((hi << 16) | lo)) {
			ret = -EIO;
			break;
		}
	}
	release_dev(d);
	kfree(ins);
	return ret;
}

static long do_set_buf(struct xlr8_ctx *c, void __user *arg)
{
	struct xlr8_dev *d = c->dev;
	struct xlr8_buf b;
	size_t size;
	unsigned long fl;
	bool inflight;
	void *buf;
	dma_addr_t dma;

	if (copy_from_user(&b, arg, sizeof(b)))
		return -EFAULT;
	if (check_zero(b.reserved, ARRAY_SIZE(b.reserved)))
		return -EINVAL;
	if (!b.size || b.size > XLR8_MAX_BUF)
		return -EINVAL;
	size = PAGE_ALIGN(b.size);

	spin_lock_irqsave(&d->lock, fl);
	inflight = (d->owner == c);
	spin_unlock_irqrestore(&d->lock, fl);
	if (inflight)
		return -EBUSY;

	buf = dma_alloc_coherent(d->dev, size, &dma, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;
	free_buf(c);
	c->buf = buf;
	c->dma = dma;
	c->size = size;
	c->submitted = c->done = false;
	b.size = size;
	return copy_to_user(arg, &b, sizeof(b)) ? -EFAULT : 0;
}

static long do_submit(struct xlr8_ctx *c, void __user *arg)
{
	struct xlr8_dev *d = c->dev;
	struct xlr8_submit s;
	unsigned long fl;
	long ret;
	int k;

	if (copy_from_user(&s, arg, sizeof(s)))
		return -EFAULT;
	if (check_zero(s.reserved, ARRAY_SIZE(s.reserved)))
		return -EINVAL;
	if (!c->buf)
		return -EINVAL;
	if (s.prog_base >= XLR8_MAX_PROG)
		return -EINVAL;
	if (d->hw_version < 0x200 && !!memchr_inv(s.args, 0, sizeof(s.args)))
		return -EOPNOTSUPP;

	ret = wait_event_interruptible(d->idle_wq, try_claim(d, c));
	if (ret)
		return ret;

	spin_lock_irqsave(&d->lock, fl);
	c->submitted = true;
	c->done = false;
	memset(&c->res, 0, sizeof(c->res));
	d->running = true;
	spin_unlock_irqrestore(&d->lock, fl);

	wr(d, R_THREADS, s.threads);
	wr(d, R_SRC, s.src);
	wr(d, R_DST, s.dst);
	wr(d, R_PROG, s.prog_base);
	if (d->hw_version >= 0x200)
		for (k = 0; k < XLR8_NARGS; k++)
			wr(d, R_ARG0 + 4 * k, s.args[k]);
	wr(d, R_MBASE, lower_32_bits(c->dma));
	wr(d, R_MLIM, c->size);
	mod_delayed_work(system_wq, &d->wd, msecs_to_jiffies(job_timeout_ms));
	wr(d, R_CTRL, CTRL_START | CTRL_IRQ_EN);    /* CTRL is written whole: keep IRQ_EN set */
	return 0;
}

static long do_wait(struct xlr8_ctx *c, void __user *arg)
{
	struct xlr8_dev *d = c->dev;
	struct xlr8_wait w;
	unsigned long fl;
	long left;

	if (copy_from_user(&w, arg, sizeof(w)))
		return -EFAULT;
	if (w.reserved_in)
		return -EINVAL;
	if (!c->submitted)
		return -EINVAL;
	if (!w.timeout_ms)
		w.timeout_ms = job_timeout_ms + 1000;

	left = wait_event_interruptible_timeout(c->wq, c->done, msecs_to_jiffies(w.timeout_ms));
	if (left < 0)
		return left;
	if (!left && !c->done)
		return -ETIMEDOUT;

	spin_lock_irqsave(&d->lock, fl);
	w = c->res;
	c->submitted = false;
	spin_unlock_irqrestore(&d->lock, fl);
	w.status |= XLR8_ST_DONE;
	return copy_to_user(arg, &w, sizeof(w)) ? -EFAULT : 0;
}

static long xlr8_ioctl(struct file *f, unsigned int cmd, unsigned long arg)
{
	struct xlr8_ctx *c = f->private_data;
	void __user *p = (void __user *)arg;

	switch (cmd) {
	case XLR8_IOC_GET_INFO:  return do_info(c, p);
	case XLR8_IOC_LOAD_PROG: return do_load_prog(c, p);
	case XLR8_IOC_SET_BUF:   return do_set_buf(c, p);
	case XLR8_IOC_SUBMIT:    return do_submit(c, p);
	case XLR8_IOC_WAIT:      return do_wait(c, p);
	default:                 return -ENOTTY;
	}
}

static int xlr8_mmap(struct file *f, struct vm_area_struct *vma)
{
	struct xlr8_ctx *c = f->private_data;

	if (!c->buf || vma->vm_pgoff)
		return -EINVAL;
	if (vma->vm_end - vma->vm_start > c->size)
		return -EINVAL;
	return dma_mmap_coherent(c->dev->dev, vma, c->buf, c->dma, c->size);
}

static __poll_t xlr8_poll(struct file *f, poll_table *wait)
{
	struct xlr8_ctx *c = f->private_data;
	__poll_t m = 0;

	poll_wait(f, &c->wq, wait);
	if (c->submitted && c->done)
		m |= EPOLLIN | EPOLLRDNORM;
	return m;
}

static const struct file_operations xlr8_fops = {
	.owner          = THIS_MODULE,
	.open           = xlr8_open,
	.release        = xlr8_release,
	.unlocked_ioctl = xlr8_ioctl,
	.compat_ioctl   = xlr8_ioctl,
	.mmap           = xlr8_mmap,
	.poll           = xlr8_poll,
	.llseek         = noop_llseek,
};

/* ---------------------------------------------------------------- platform driver */

/* The S_AXI_HP0 port powers up 64 bits wide; XLR8's master is 32 bits. */
static void force_hp0_32bit(struct xlr8_dev *d)
{
	void __iomem *afi = ioremap(AFI0_BASE, 0x1000);

	if (!afi) {
		dev_warn(d->dev, "cannot map the HP0 interface registers\n");
		return;
	}
	iowrite32(ioread32(afi + 0x00) | 1, afi + 0x00);    /* AFI_RDCHAN_CTRL.FabricWidth */
	iowrite32(ioread32(afi + 0x14) | 1, afi + 0x14);    /* AFI_WRCHAN_CTRL.FabricWidth */
	iounmap(afi);
}

static void xlr8_clk_off(void *clk)
{
	clk_disable_unprepare(clk);
}

static int xlr8_probe(struct platform_device *pdev)
{
	struct xlr8_dev *d;
	u32 id, hz;
	int ret;

	d = devm_kzalloc(&pdev->dev, sizeof(*d), GFP_KERNEL);
	if (!d)
		return -ENOMEM;
	d->dev = &pdev->dev;
	spin_lock_init(&d->lock);
	init_waitqueue_head(&d->idle_wq);
	INIT_DELAYED_WORK(&d->wd, watchdog);

	d->regs = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(d->regs))
		return PTR_ERR(d->regs);
	d->irq = platform_get_irq(pdev, 0);
	if (d->irq < 0)
		return d->irq;
	ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(32));
	if (ret)
		return ret;

	/*
	 * The design is timed at 50 MHz. The PL clock comes up at a different rate when the bitstream
	 * is loaded through the FPGA manager (100 MHz on this image), so set it from the device tree.
	 */
	d->clk = devm_clk_get(&pdev->dev, "pl_clk");
	if (IS_ERR(d->clk))
		return dev_err_probe(&pdev->dev, PTR_ERR(d->clk), "no pl_clk in the device tree\n");
	if (!of_property_read_u32(pdev->dev.of_node, "clock-frequency", &hz)) {
		ret = clk_set_rate(d->clk, hz);
		if (ret)
			return dev_err_probe(&pdev->dev, ret, "cannot set the PL clock to %u Hz\n", hz);
	}
	ret = clk_prepare_enable(d->clk);
	if (ret)
		return ret;
	ret = devm_add_action_or_reset(&pdev->dev, xlr8_clk_off, d->clk);
	if (ret)
		return ret;
	dev_info(&pdev->dev, "PL clock %lu Hz\n", clk_get_rate(d->clk));

	force_hp0_32bit(d);
	id = rd(d, R_ID);
	if (id != XLR8_ID_VALUE) {
		dev_err(&pdev->dev, "unexpected ID %08x (bitstream not loaded?)\n", id);
		return -ENODEV;
	}
	d->hw_version = rd(d, R_VER);
	wr(d, R_IRQ, 3);

	ret = devm_request_irq(&pdev->dev, d->irq, xlr8_irq, 0, DRV_NAME, d);
	if (ret)
		return ret;

	d->misc.minor = MISC_DYNAMIC_MINOR;
	d->misc.name = DRV_NAME;
	d->misc.fops = &xlr8_fops;
	d->misc.parent = &pdev->dev;
	ret = misc_register(&d->misc);
	if (ret)
		return ret;
	platform_set_drvdata(pdev, d);
	dev_info(&pdev->dev, "XLR8 hw %08x, irq %d, /dev/%s\n", rd(d, R_VER), d->irq, DRV_NAME);
	return 0;
}

static int xlr8_remove(struct platform_device *pdev)
{
	struct xlr8_dev *d = platform_get_drvdata(pdev);

	misc_deregister(&d->misc);
	cancel_delayed_work_sync(&d->wd);
	hw_soft_reset(d);
	return 0;
}

static const struct of_device_id xlr8_of_match[] = {
	{ .compatible = "ramselvaraj,xlr8-1.0" },
	{ }
};
MODULE_DEVICE_TABLE(of, xlr8_of_match);

static struct platform_driver xlr8_driver = {
	.probe  = xlr8_probe,
	.remove = xlr8_remove,
	.driver = { .name = DRV_NAME, .of_match_table = xlr8_of_match },
};
module_platform_driver(xlr8_driver);

MODULE_DESCRIPTION("XLR8 SIMT GPU accelerator");
MODULE_AUTHOR("Ram Selvaraj");
MODULE_LICENSE("GPL");
