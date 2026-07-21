#!/bin/bash

cleanup_lo() {
  ( ( losetup | grep "$STOCK_FIRMWARE" | awk '{print $1}' ) || true ) | while read l; do losetup -d $l; done
}

cleanup() {
  umount */* 2>/dev/null || true
  rm -rf orig out .files
  cleanup_lo
}

set -eo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root" 1>&2
  exit
fi

ALIGN=$((4 * 1024 * 1024)) # 4 MiB

SUPER_SIZE=7516192768

# NOS 4.1 system/system_ext outgrew arter97's 4.0 ext4 caps and all-ext4 can't fit the 7GiB super.
# Build them as erofs (compressed, read-only) like product already is and like stock 4.1 ships them.
ODM_SIZE=2
PRODUCT_SIZE=0
SYSTEM_EXT_SIZE=1400
SYSTEM_SIZE=1600
VENDOR_DLKM_SIZE=45
# erofs (0): without 64bo the 32-bit vendor libs are kept, so vendor no longer fits ext4; compress it like stock
VENDOR_SIZE=0

ACTIVE_SLOT=a
INACTIVE_SLOT=b

STOCK_FIRMWARE=/home/sappy/projects/nothingmuch-pong/dyn-4.1

TMP=/tmp/$(uuidgen)

MKFS="mkfs.ext4 \
  -b 4096 \
  -O ^has_journal \
  -E lazy_itable_init=0,lazy_journal_init=0,nodiscard \
  -F -m 0"

AVB=../avb/avbtool.py
AVB_KEY=../avb/test/data/testkey_rsa4096_pub.pem

avb_get_orig_size() {
  RET=$($AVB info_image --image "$1" | grep '^Original image size:' | awk '{print $4}')
  if [ -z "$RET" ]; then
    echo $(stat -L -c%s "$1")
  else
    echo "$1 orig size = $RET" 1>&2
    echo $RET
  fi
}

MOD=$( ( ls files; ( grep -o '^[^#]*' remove.txt || true ) | awk -F/ '{print $1}' ) | sort | uniq | tr '\n' ' ')

cleanup

mkdir -p out
for f in "$STOCK_FIRMWARE/"*.img; do
  ln -s $(losetup -f --show -b 4096 --sizelimit $(avb_get_orig_size "$f") "$f") out/$(basename $f)
done
for i in $MOD; do
  mkdir -p orig/$i out/$i
  mount -o ro out/$i.img orig/$i

 (
  if grep -o '^[^#]*' remove.txt | grep -q "^$i/"; then
    TMP=/tmp/custom-super-$(uuidgen)
    grep -o '^[^#]*' remove.txt | grep "^$i/" | cut -c$((${#i} + 2))- > $TMP
    rsync -ahAXx --exclude-from $TMP --inplace --numeric-ids orig/$i/ out/$i/
    rm $TMP
  else
    rsync -ahAXx --inplace --numeric-ids orig/$i/ out/$i/
  fi
  echo "Copying $i done"
 ) &
done

wait

echo "Adding files"
rsync -ahAX --inplace --numeric-ids files/ .files/
cd .files/
# Restore recorded file attributes
setfacl -P --restore=../attr/acl.txt
setfattr -h --restore=../attr/xattr.txt
# Override them from stock attributes
LIST=$(find .)
# NOS 4.1 makes bionic (libc/libm) symlinks into the runtime APEX -> ELOOP on offline stock mount.
# Those files are replaced from files/ anyway (also in remove.txt), so tolerate unreadable stock attrs.
( cd ../orig; getfacl -Pn $(ls -d $LIST 2>/dev/null) ) | setfacl -P --restore=- || true
( cd ../orig; getfattr -dhP -m- $(ls -d $LIST 2>/dev/null) ) | setfattr -h --restore=- || true
( find */ -exec ls -aldnZ {} + | grep '?' ) || true
cd ..
rsync -ahAX --inplace --numeric-ids .files/ out/
rm -rf .files

cd append
find -type f | while read f; do
  cat "$f" >> ../out/"$f"
done
cd ..

echo "Running custom plugins"
# run-parts replacement (not packaged on Arch); explicit order matching alphabetical run-parts
# 64bo (64-bit-only) is REQUIRED: NOS 4.1 ships no 32-bit libntf.so, so 32-bit zygote can't
# start (libhwui->libntf link fails) -> boot hang. Device is 64-bit-primary by design.
# The WebView bundled in files/ is 32-bit and won't work here; sourcing a real 64-bit WebView.
for pl in plugins/64bo plugins/jemalloc plugins/overlay plugins/prop; do
  echo "run-parts: executing $pl"
  bash "$pl"
done

echo "Unmounting"
for i in $MOD; do
  umount "orig/$i" &
done

wait

echo "Creating images"
for i in $MOD; do
 (
  eval SIZE='$'$(echo $i | tr '[:lower:]' '[:upper:]')_SIZE
  SIZE=$(($SIZE * 1024 * 1024))

  rm out/$i.img
  if [[ "$SIZE" == "0" ]]; then
    # Assume erofs
    mkfs.erofs -zlz4 -T0 --ignore-mtime out/$i.img out/$i
  else
    fallocate -l $SIZE out/$i.img
    $MKFS -L $i -d out/$i out/$i.img
  fi

  echo Created $i: original size = $(du -sh --apparent-size "$STOCK_FIRMWARE/$i.img" | awk '{print $1}'), new size = $(du -sh --apparent-size "out/$i.img" | awk '{print $1}')
 ) &
done

wait

echo "Creating super.img"
# Create argument list
ARG=""
while read img; do
  PART_NAME=$(echo $img | sed 's/\.img//g')
  eval SIZE='$'$(echo $PART_NAME | tr '[:lower:]' '[:upper:]')_SIZE
  if [[ "$SIZE" == "0" ]]; then
    SIZE=$(stat -c%s out/$img)
  else
    SIZE=$(($SIZE * 1024 * 1024))
  fi
  ARG="$ARG -p ${PART_NAME}_${INACTIVE_SLOT}:none:0:qti_dynamic_partitions_${INACTIVE_SLOT}"
  ARG="$ARG -p ${PART_NAME}_${ACTIVE_SLOT}:none:${SIZE}:qti_dynamic_partitions_${ACTIVE_SLOT} -i ${PART_NAME}_${ACTIVE_SLOT}=out/$img"
done < <(ls out/ | grep '\.img$')

set -x
lpmake \
    -d $SUPER_SIZE \
    --metadata-size=65536 \
    --metadata-slots=3 \
    --alignment=$ALIGN \
    --alignment-offset=$ALIGN \
    --super-name=super \
    --virtual-ab \
    --sparse \
    -o out/super.img \
    -g qti_dynamic_partitions_${INACTIVE_SLOT}:$(($SUPER_SIZE - $ALIGN)) \
    -g qti_dynamic_partitions_${ACTIVE_SLOT}:$(($SUPER_SIZE - $ALIGN)) \
    $ARG
set +x
cleanup_lo

ls -al out/super.img
