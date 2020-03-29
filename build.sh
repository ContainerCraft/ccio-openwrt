#!/bin/sh

set -e

arch_lxd=x86_64
ver=19.07.0
dist=openwrt
type=lxd
super=fakeroot
# iptables-mod-checksum is required by the work-around inserted by files/etc/uci-defaults/70_fill-dhcp-checksum.
packages=iptables-mod-checksum

# Workaround for Debian/Ubuntu systems which use C.UTF-8 which is unsupported by OpenWrt
export LC_ALL=C

usage() {
	echo "Usage: $0 [-a|--arch x86_64|i686|aarch64|aarch32] [-v|--version <version>] [-p|--packages <packages>] [-f|--files] [-t|--type lxd|plain] [-s|--super fakeroot|sudo] [--help]"
	exit 1
}

temp=$(getopt -o "a:v:p:f:t:s:" -l "arch:,version:,packages:,files:,type:,super:,help" -- "$@")
eval set -- "$temp"
while true; do
	case "$1" in
	-a|--arch)
		arch_lxd="$2"; shift 2;;
	-v|--version)
		ver="$2"; shift 2;;
	-p|--packages)
		packages="$2"; shift 2;;
	-f|--files)
		files="$2"; shift 2;;
	-t|--type)
		type="$2"
		shift 2

		case "$type" in
		lxd|plain)
			;;
		*)
			usage;;
		esac;;
	-s|--super)
		super="$2"
		shift 2

		case "$super" in
		fakeroot|sudo)
			;;
		*)
			usage;;
		esac;;
	--help)
		usage;;
	--)
		shift; break;;
	esac
done

if [ $# -ne 0 ]; then
        usage
fi

case "$arch_lxd" in
	i686)
		arch=x86
		subarch=generic
		arch_ipk=i386_pentium4
		;;
	x86_64)
		arch=x86
		subarch=64
		arch_ipk=x86_64
		;;
	aarch64)
		arch=armvirt
		subarch=64
		arch_ipk=aarch64_generic
		;;
    aarch32)
		arch=armvirt
		subarch=32
		arch_ipk=aarch32_generic
		;;
	*)
		usage
		;;
esac

branch_ver=$(echo "${ver}"|cut -d- -f1|cut -d. -f1,2)

if test $ver = snapshot; then
	openwrt_branch=snapshot
	procd_url=https://github.com/openwrt/openwrt/trunk/package/system/procd
	openwrt_url=https://downloads.openwrt.org/snapshots/targets/${arch}/${subarch}
else
	openwrt_branch=${dist}-${branch_ver}
	procd_url=https://github.com/openwrt/openwrt/branches/${openwrt_branch}/package/system/procd
	openwrt_url=https://downloads.openwrt.org/releases/${ver}/targets/${arch}/${subarch}
fi

procd_extra_ver=lxd-3

tarball=bin/${dist}-${ver}-${arch}-${subarch}-${type}.tar.gz
metadata=bin/metadata.yaml
pkgdir=bin/${ver}/packages/${arch}/${subarch}

detect_url() {
	local pattern="$1"
	download_sums ${openwrt_url}/dummy
	local sums=$return
	return=$(cat $sums|grep "$pattern"|cut -d' ' -f2-|cut -c2-)
	if [ -z "$return" ]; then
		echo "URL autodetection failed: $pattern"
		exit 1
	fi
}

download_rootfs() {
	detect_url "rootfs\.tar"
	local rootfs_url=$openwrt_url/$return

	# global $rootfs
	rootfs=dl/$(basename $rootfs_url)

	download $rootfs_url $rootfs
	check $rootfs $rootfs_url
}

download_sdk() {
	detect_url "sdk"
	local sdk_url=$openwrt_url/$return
	local sdk_tar=dl/$(basename $sdk_url)

	download $sdk_url $sdk_tar
	check $sdk_tar $sdk_url

	# global $sdk
	sdk="build_dir/$(tar tf $sdk_tar|head -1)"

	if ! test -e $sdk; then
		test -e build_dir || mkdir build_dir
		tar xvf $sdk_tar -C build_dir
	fi
}

download() {
	url=$1
	dst=$2
	dir=$(dirname $dst)

	if ! test -e "$dst" ; then
		echo Downloading $url
		test -e $dir || mkdir $dir

		wget -O $dst "$url"
	fi
}

download_sums() {
	local url=$1

	local sums_url="$(dirname $url)/sha256sums"
	local sums_file="dl/sha256sums_$(echo $sums_url|md5sum|cut -d ' ' -f 1)"

	if ! test -e $sums_file; then
		test -e "dl" || mkdir "dl"
		wget -O $sums_file $sums_url
	fi

	return=$sums_file
}

check() {
	local dst=$1
	local dst_url=$2

	download_sums $dst_url
	local sums=$return

	local dst_sum="$(grep $(basename $dst_url) $sums|cut -d ' ' -f 1)"

	sum=$(sha256sum $dst| cut -d ' ' -f1)
	if test -z "$dst_sum" -o "$dst_sum" != $sum; then
		echo Bad checksum $sum of $dst
		exit 1
	fi
}

need_procd() {
	if ls patches/procd-${openwrt_branch}/*.patch 2>/dev/null >/dev/null; then
		return 0
	else
		return 1
	fi
}

download_procd() {
	if ! test -e dl/procd-${openwrt_branch}; then
		svn export $procd_url dl/procd-${openwrt_branch}
		sed -i -e "s/PKG_RELEASE:=\(\S\+\)/PKG_RELEASE:=\1-${procd_extra_ver}/" dl/procd-${openwrt_branch}/Makefile
	fi

	test -e dl/procd-${openwrt_branch}/patches || mkdir dl/procd-${openwrt_branch}/patches
	cp -a patches/procd-${openwrt_branch}/*.patch dl/procd-${openwrt_branch}/patches
}

build_procd() {
	rm $sdk/package/lxd-procd||true
	ln -sfT $(pwd)/dl/procd-${openwrt_branch} $sdk/package/lxd-procd

	local date=$(grep PKG_SOURCE_DATE:= dl/procd-${openwrt_branch}/Makefile | cut -d '=' -f 2)
	local version=$(grep PKG_SOURCE_VERSION:= dl/procd-${openwrt_branch}/Makefile | cut -d '=' -f 2 | cut -b '1-8')
	local release=$(grep PKG_RELEASE:= dl/procd-${openwrt_branch}/Makefile | cut -d '=' -f 2)
	local ipk_old=$sdk/bin/targets/${arch}/${subarch}/packages/procd_${date}-${version}-${release}_*.ipk
	local ipk_new=$sdk/bin/packages/${arch_ipk}/base/procd_${date}-${version}-${release}_*.ipk

	if test $ver \< 18; then
		local ipk=$ipk_old
	else
		local ipk=$ipk_new
	fi

	if ! test -s $ipk; then
	(cd $sdk &&
	./scripts/feeds update base &&
	./scripts/feeds install libubox && test -d package/feeds/base/libubox &&
	./scripts/feeds install ubus && test -d package/feeds/base/ubus &&
	make defconfig &&
	make package/lxd-procd/compile
	)
	fi
	test -e ${pkgdir} || mkdir -p ${pkgdir}
	(cd ${pkgdir} && ln -sf ../../../../../$ipk .)
}

build_tarball() {
	export SDK="$(pwd)/${sdk}"
	local opts=""
	if test ${type} = lxd; then
		opts="$opts -m $metadata"
	fi
	if test ${ver} != snapshot; then
		opts="$opts --upgrade"
	fi
	local allpkgs="${packages}"
	test -d $pkgdir && for pkg in $pkgdir/*.ipk; do
		if [ -e "$pkg" ]; then
			allpkgs="${allpkgs} $pkg"
		fi
	done

	local cmd="scripts/build_rootfs.sh"
	if test `id -u` != 0; then
		case "$super" in
			sudo)
				cmd="sudo --preserve-env=SDK $cmd"
				;;
			*)
				cmd="$super $cmd"
				;;
		esac
	fi

	$cmd $rootfs $opts -o $tarball --disable-services="sysfixtime sysntpd led" --arch=${arch} --subarch=${subarch} --packages="${allpkgs}" --files="${files}"
}

build_metadata() {
	local stat=`stat -c %Y $rootfs`
	local date="`date -d \"@${stat}\" +%F`"
	local desc="$(tar xf $rootfs ./etc/openwrt_release -O|grep DISTRIB_DESCRIPTION|sed -e "s/.*='\(.*\)'/\1/")"

	test -e bin || mkdir bin
	cat > $metadata <<EOF
architecture: "$arch_lxd"
creation_date: $(date +%s)
properties:
 architecture: "$arch_lxd"
 description: "$desc"
 os: "OpenWrt"
 release: "$ver"
templates:
EOF

## Add templates
#
# templates:
#   /etc/hostname:
#     when:
#       - start
#     template: hostname.tpl
}

download_rootfs
download_sdk
if need_procd; then
	download_procd
	build_procd
fi
build_metadata
build_tarball

echo "Tarball built: $tarball"
