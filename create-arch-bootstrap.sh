#!/usr/bin/env bash

# Dependencies: curl tar gzip grep coreutils
# Root rights are required
source settings.sh

check_command_available() {
	for cmd in "$@"; do
		if ! command -v "$cmd" >&-; then
			echo "$cmd is required!"
			exit 1
		fi
	done
}
check_command_available curl gzip grep sha256sum

if [ $EUID != 0 ]; then
	echo "Root rights are required!"
	exit 1
fi

script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
bootstrap="${script_dir}"/root.x86_64

mount_chroot () {
	mount --bind "${bootstrap}" "${bootstrap}"
	mount -t proc /proc "${bootstrap}"/proc
	mount --bind /sys "${bootstrap}"/sys
	mount --make-rslave "${bootstrap}"/sys
	mount --bind /dev "${bootstrap}"/dev
	mount --bind /dev/pts "${bootstrap}"/dev/pts
	mount --bind /dev/shm "${bootstrap}"/dev/shm
	mount --make-rslave "${bootstrap}"/dev

	rm -f "${bootstrap}"/etc/resolv.conf
	cp /etc/resolv.conf "${bootstrap}"/etc/resolv.conf
	cp "${script_dir}"/settings.sh "${bootstrap}"/conty_settings.sh

	mkdir -p "${bootstrap}"/run/shm
}

unmount_chroot () {
	umount -l "${bootstrap}"
	umount "${bootstrap}"/proc
	umount "${bootstrap}"/sys
	umount "${bootstrap}"/dev/pts
	umount "${bootstrap}"/dev/shm
	umount "${bootstrap}"/dev
}

run_in_chroot () {
	if [ -n "${CHROOT_AUR}" ]; then
		chroot --userspec=aur:aur "${bootstrap}" /usr/bin/env LANG=en_US.UTF-8 TERM=xterm PATH="/bin:/sbin:/usr/bin:/usr/sbin" "$@"
	else
		chroot "${bootstrap}" /usr/bin/env LANG=en_US.UTF-8 TERM=xterm PATH="/bin:/sbin:/usr/bin:/usr/sbin" "$@"
	fi
}

install_packages () {
	source /conty_settings.sh
	echo "Checking if packages are present in the repos, please wait..."

	declare -a bad_pkglist
	mapfile -t bad_pkglist < <(comm -23 \
									<(printf '%s\n' "${PACKAGES[@]}" | sort -u) \
									<(pacman -Slq | sort -u))
	if [ "${#bad_pkglist[@]}" -gt 0 ]; then
		echo "These packages are not available in arch repositories: " "${bad_pkglist[@]}"
		exit 1
	fi

	for i in {1..10}; do
		if pacman --noconfirm --needed -S "${PACKAGES[@]}" || [ "$?" -gt 127 ]; then
			break
		fi
	done

}

install_aur_packages () {
	cd /home/aur

	echo "Checking if packages are present in the AUR, please wait..."
	for p in ${aur_pkgs}; do
		if ! yay -a -G "${p}" &>/dev/null; then
			bad_aur_pkglist="${bad_aur_pkglist} ${p}"
		fi
	done

	if [ -n "${bad_aur_pkglist}" ]; then
		echo ${bad_aur_pkglist} > /home/aur/bad_aur_pkglist.txt
	fi

	for i in {1..10}; do
		if yes | yay --needed --removemake --builddir /home/aur -a -S ${aur_pkgs}; then
			break
		fi
	done
}

generate_pkg_licenses_file () {
	pacman -Qi | grep -E '^Name|Licenses' |  cut -d ":" -f 2 | paste -d ' ' - - > /pkglicenses.txt
}

generate_localegen () {
	printf '%s\n' "${LOCALES[@]}" > locale.gen
}

generate_mirrorlist () {
	printf '%s\n' "$MIRRORLIST" > mirrorlist
}

cd "${script_dir}" || exit 1

bootstrap_filename="archlinux-bootstrap-x86_64.tar.zst"
sha256sums_filename="sha256sums.txt"

curl -#fLO "$BOOTSTRAP_SHA256SUM_FILE_URL" || { echo "Failed to download $sha256sums_filename file"; exit 1; }

for link in "${BOOTSTRAP_DOWNLOAD_URLS[@]}"; do
	# Clean up any previous failed download
	rm -f "$bootstrap_filename"

	echo "Downloading Arch Linux bootstrap from $link"
	if curl -#fL -o "$bootstrap_filename" "$link"; then
		echo "Verifying the integrity of the bootstrap"
		# Check the downloaded file against the correct checksum from the file
		if grep "$bootstrap_filename" "$sha256sums_filename" | sha256sum --check --status; then
			echo "Bootstrap verification successful."
			bootstrap_is_good=1
			break
		else
			echo "Checksum verification failed for download from $link."
		fi
	else
		echo "Download from $link failed."
	fi
	echo "Trying next mirror..."
done

if [ -z "${bootstrap_is_good}" ]; then
	echo "Bootstrap download failed or its checksum is incorrect after trying all mirrors."
	exit 1
fi

# Unmount first just in case
unmount_chroot

rm -rf "${bootstrap}"
tar xf "$bootstrap_filename"
rm "$bootstrap_filename" "$sha256sums_filename"

mount_chroot

generate_localegen

if command -v reflector 1>/dev/null; then
	echo "Generating mirrorlist..."
	reflector --connection-timeout 10 --download-timeout 10 --protocol https --score 10 --sort rate --save mirrorlist
	reflector_used=1
else
	generate_mirrorlist
fi

rm "${bootstrap}"/etc/locale.gen
mv locale.gen "${bootstrap}"/etc/locale.gen

rm "${bootstrap}"/etc/pacman.d/mirrorlist
mv mirrorlist "${bootstrap}"/etc/pacman.d/mirrorlist

{
	echo
	echo "[multilib]"
	echo "Include = /etc/pacman.d/mirrorlist"
} >> "${bootstrap}"/etc/pacman.conf

run_in_chroot pacman-key --init
run_in_chroot pacman-key --populate archlinux

# Add CachyOS repo
run_in_chroot pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
run_in_chroot pacman-key --lsign-key F3B607488DB35A47

if ! run_in_chroot pacman --noconfirm -U 'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-keyring-20240331-1-any.pkg.tar.zst' \
'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-mirrorlist-22-1-any.pkg.tar.zst' \
'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-v3-mirrorlist-22-1-any.pkg.tar.zst' \
'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-v4-mirrorlist-22-1-any.pkg.tar.zst'; then
    echo "Seems like CachyOS keyring or mirrorlist is currently unavailable"
    echo "Please try again later"
    exit 1
fi

cp "${bootstrap}/etc/pacman.conf" "${bootstrap}/etc/pacman.conf.bak"

cat > "${bootstrap}/etc/pacman.conf" <<EOF
[options]
Architecture = x86_64 x86_64_v${CACHYOS_CPU_LEVEL}

# Include Repo-Dateien (Reihenfolge definiert Priorität)
Include = /etc/pacman.d/cachyos.conf
Include = /etc/pacman.d/cachyos-v${CACHYOS_CPU_LEVEL}.conf
Include = /etc/pacman.d/multilib.conf
Include = /etc/pacman.d/core.conf
Include = /etc/pacman.d/extra.conf
Include = /etc/pacman.d/community.conf
EOF

cat > "${bootstrap}/etc/pacman.d/cachyos.conf" <<EOF
[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
EOF

if [ -n "$CACHYOS_CPU_LEVEL" ] && [ "$CACHYOS_CPU_LEVEL" -ge 3 ]; then
  cat > "${bootstrap}/etc/pacman.d/cachyos-v${CACHYOS_CPU_LEVEL}.conf" <<EOF
[cachyos-v${CACHYOS_CPU_LEVEL}]
Include = /etc/pacman.d/cachyos-v${CACHYOS_CPU_LEVEL}-mirrorlist

[cachyos-core-v${CACHYOS_CPU_LEVEL}]
Include = /etc/pacman.d/cachyos-v${CACHYOS_CPU_LEVEL}-mirrorlist

[cachyos-extra-v${CACHYOS_CPU_LEVEL}]
Include = /etc/pacman.d/cachyos-v${CACHYOS_CPU_LEVEL}-mirrorlist
EOF
else
  : > "${bootstrap}/etc/pacman.d/cachyos-v${CACHYOS_CPU_LEVEL}.conf"
fi

awk '/^\[multilib\]/{print;getline; print;exit}' "${bootstrap}/etc/pacman.conf.bak" > "${bootstrap}/etc/pacman.d/multilib.conf"
awk '/^\[core\]/{print;getline; print;exit}' "${bootstrap}/etc/pacman.conf.bak" > "${bootstrap}/etc/pacman.d/core.conf"
awk '/^\[extra\]/{print;getline; print;exit}' "${bootstrap}/etc/pacman.conf.bak" > "${bootstrap}/etc/pacman.d/extra.conf"
awk '/^\[community\]/{print;getline; print;exit}' "${bootstrap}/etc/pacman.conf.bak" > "${bootstrap}/etc/pacman.d/community.conf"

sed -i '/^\[.*\]/,$d' "${bootstrap}/etc/pacman.conf.bak"

grep -v '^\[.*\]' "${bootstrap}/etc/pacman.conf.bak" >> "${bootstrap}/etc/pacman.conf"

sed -i 's/#NoExtract   =/NoExtract   = usr\/lib\/firmware\/nvidia\/\* usr\/share\/man\/\*/' "${bootstrap}/etc/pacman.conf"

run_in_chroot pacman -Sy archlinux-keyring --noconfirm
run_in_chroot pacman -Su --noconfirm

date -u +"%d-%m-%Y %H:%M (DMY UTC)" > "${bootstrap}"/version

# These packages are required for the self-update feature to work properly
run_in_chroot pacman --noconfirm --needed -S base reflector squashfs-tools fakeroot

# Regenerate the mirrorlist with reflector if reflector was not used before
if [ -z "${reflector_used}" ]; then
	echo "Generating mirrorlist..."
	run_in_chroot reflector --connection-timeout 10 --download-timeout 10 --protocol https --score 10 --sort rate --save /etc/pacman.d/mirrorlist
 	run_in_chroot pacman -Syu --noconfirm
fi

export -f install_packages
if ! run_in_chroot bash -c install_packages; then
	unmount_chroot
	exit 1
fi

if [ "${#AUR_PACKAGES[@]}" -ne 0 ]; then
	run_in_chroot pacman --noconfirm --needed -S base-devel yay
	run_in_chroot useradd -m -G wheel aur
	echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" >> "${bootstrap}"/etc/sudoers

	for p in "${AUR_PACKAGES[@]}"; do
		aur_pkgs="${aur_pkgs} aur/${p}"
	done
	export aur_pkgs

	export -f install_aur_packages
	CHROOT_AUR=1 HOME=/home/aur run_in_chroot bash -c install_aur_packages
	mv "${bootstrap}"/home/aur/bad_aur_pkglist.txt "${bootstrap}"/opt
	rm -rf "${bootstrap}"/home/aur
fi

run_in_chroot locale-gen

echo "Generating package info, please wait..."

# Generate a list of installed packages
run_in_chroot pacman -Q > "${bootstrap}"/pkglist.x86_64.txt

# Generate a list of licenses of installed packages
export -f generate_pkg_licenses_file
run_in_chroot bash -c generate_pkg_licenses_file

unmount_chroot

# Clear pacman package cache
rm -f "${bootstrap}"/var/cache/pacman/pkg/*

# Create some empty files and directories
# This is needed for bubblewrap to be able to bind real files/dirs to them
# later in the conty-start.sh script
mkdir "${bootstrap}"/media
mkdir "${bootstrap}"/initrd
mkdir -p "${bootstrap}"/usr/share/steam/compatibilitytools.d
touch "${bootstrap}"/etc/asound.conf
touch "${bootstrap}"/etc/localtime
chmod 755 "${bootstrap}"/root

if [ ! -d "${bootstrap}/etc/fonts/conf.d" ]; then
    mkdir -p "${bootstrap}/etc/fonts/conf.d"
fi

# Enable full font hinting
rm -f "${bootstrap}"/etc/fonts/conf.d/10-hinting-slight.conf
ln -s /usr/share/fontconfig/conf.avail/10-hinting-full.conf "${bootstrap}"/etc/fonts/conf.d

clear
echo "Done"

if [ -f "${bootstrap}"/opt/bad_aur_pkglist.txt ]; then
	echo
	echo "These packages are either not in the AUR or yay failed to download their"
	echo "PKGBUILDs:"
	cat "${bootstrap}"/opt/bad_aur_pkglist.txt
	rm "${bootstrap}"/opt/bad_aur_pkglist.txt
fi

