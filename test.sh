
loop="/dev/loop3"
if lsblk | grep -o "$(echo $loop | grep -o '[^/]\+$')p1.*" | grep -oq '[^ ]\+$'; then
        mount=$(lsblk | grep -o "$(echo $loop | grep -o '[^/]\+$')p1.*" | grep -o '[^ ]\+$')
        echo "mounted ${mount}"
        mount=$(udisksctl unmount -b ${loop}p1 | grep -o '[^ ]\+$')
else
        mount=$(udisksctl mount -b ${loop}p1 | grep -o '[^ ]\+$')
        echo "not mounted"
fi