# Shared helpers for the board scripts. Source this file.
#   BOARD     user@host (default: discovered)
#   SSH_ASKPASS  must print the board password (never put the password on a command line)
export SSH_ASKPASS_REQUIRE=force DISPLAY=${DISPLAY:-:0}
SSHO="-o PubkeyAuthentication=no -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8"

find_board() {
  # The board's DHCP address changes across reboots: find the host answering both ssh and the
  # PYNQ Jupyter port 9090 on the local /24.
  [ -n "${BOARD:-}" ] && return 0
  local net ip
  local dev
  dev=$(ip -4 route show default | awk '{print $5; exit}')
  net=$(ip -4 -o addr show dev "$dev" scope global | awk '{print $4}' | head -1 | cut -d. -f1-3)
  for i in $(seq 1 254); do
    ( timeout 1 bash -c "echo > /dev/tcp/$net.$i/22" 2>/dev/null && \
      timeout 1 bash -c "echo > /dev/tcp/$net.$i/9090" 2>/dev/null && echo "$net.$i" ) &
  done > /tmp/xlr8_find_board.$$ ; wait
  ip=$(head -1 /tmp/xlr8_find_board.$$); rm -f /tmp/xlr8_find_board.$$
  [ -z "$ip" ] && { echo "board not found on $net.0/24" >&2; return 1; }
  export BOARD="xilinx@$ip"
}

bssh()  { ssh $SSHO "$BOARD" "$@"; }
bscp()  { scp $SSHO -q "$@"; }
# run a command as root on the board; the password goes over stdin
bsudo() { "$SSH_ASKPASS" | ssh $SSHO "$BOARD" "sudo -S -p '' bash -c $(printf '%q' "$*")"; }
