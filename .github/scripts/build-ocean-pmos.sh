#!/usr/bin/env bash

set -Eeuo pipefail

kernel_source="${GITHUB_WORKSPACE:-$(pwd)}"
ci_root="${RUNNER_TEMP:-${kernel_source}/.ci-work}"
pmbootstrap_dir="${ci_root}/pmbootstrap"
pmaports_dir="${ci_root}/pmaports"
pmb_work="${ci_root}/pmbootstrap-work"
pmb_config="${ci_root}/pmbootstrap_v3.cfg"
output_dir="${OUTPUT_DIR:-${kernel_source}/out}"
build_mode="${BUILD_MODE:-boot}"
pmbootstrap_ref="${PMBOOTSTRAP_REF:-main}"
pmaports_ref="${PMAPORTS_REF:-main}"
kernel_package="linux-postmarketos-qcom-msm8953"
device="qcom-msm8953"

case "${build_mode}" in
	boot | kernel) ;;
	*)
		echo "Unsupported BUILD_MODE: ${build_mode}" >&2
		exit 2
		;;
esac

mkdir -p "${ci_root}" "${output_dir}"

clone_ref() {
	local url="$1"
	local ref="$2"
	local destination="$3"

	git init -q "${destination}"
	git -C "${destination}" remote add origin "${url}"
	git -C "${destination}" fetch -q --depth=1 origin "${ref}"
	git -C "${destination}" checkout -q --detach FETCH_HEAD
}

echo "Cloning pmbootstrap at ${pmbootstrap_ref}"
clone_ref \
	"https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git" \
	"${pmbootstrap_ref}" \
	"${pmbootstrap_dir}"

echo "Cloning pmaports at ${pmaports_ref}"
clone_ref \
	"https://gitlab.postmarketos.org/postmarketOS/pmaports.git" \
	"${pmaports_ref}" \
	"${pmaports_dir}"

pmbootstrap="${pmbootstrap_dir}/pmbootstrap.py"

if [[ ! -f "${pmbootstrap}" ]]; then
	echo "pmbootstrap.py was not found after checkout" >&2
	exit 1
fi

if ! find "${pmaports_dir}" -type f -path "*/${kernel_package}/APKBUILD" -print -quit | grep -q .; then
	echo "${kernel_package} is not present in the selected pmaports revision" >&2
	exit 1
fi

python3 "${pmbootstrap}" -c "${pmb_config}" config work "${pmb_work}"
python3 "${pmbootstrap}" -c "${pmb_config}" config aports "${pmaports_dir}"
python3 "${pmbootstrap}" -c "${pmb_config}" config device "${device}"
python3 "${pmbootstrap}" -c "${pmb_config}" config ui none
python3 "${pmbootstrap}" -c "${pmb_config}" config user pmos

pmb_common=(
	python3 "${pmbootstrap}"
	-c "${pmb_config}"
	-p "${pmaports_dir}"
	-w "${pmb_work}"
	-j "$(nproc)"
	-t 3600
	-y
	--no-ccache
	--details-to-stdout
)

cleanup() {
	"${pmb_common[@]}" shutdown >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Building ${kernel_package} from ${kernel_source}"
"${pmb_common[@]}" \
	-l "${output_dir}/pmbootstrap-build.log" \
	build \
	--force \
	--arch aarch64 \
	--src "${kernel_source}" \
	"${kernel_package}"

mkdir -p "${output_dir}/packages"

while IFS= read -r -d '' package; do
	cp -v "${package}" "${output_dir}/packages/"
done < <(find "${pmb_work}/packages" -type f \
	-name "${kernel_package}-*.apk" -print0)

if ! find "${output_dir}/packages" -type f -name "${kernel_package}-*.apk" \
	-print -quit | grep -q .; then
	echo "The kernel build completed but its APK could not be located" >&2
	exit 1
fi

if [[ "${build_mode}" == "boot" ]]; then
	echo "Generating a minimal rootfs and lk2nd-compatible boot artifacts"
	"${pmb_common[@]}" \
		-l "${output_dir}/pmbootstrap-install.log" \
		install \
		--no-image \
		--no-recommends \
		--password 147147

	mkdir -p "${output_dir}/export"
	"${pmb_common[@]}" \
		-l "${output_dir}/pmbootstrap-export.log" \
		export \
		"${output_dir}/export"
fi

{
	echo "build_mode=${build_mode}"
	echo "device=${device}"
	echo "kernel_package=${kernel_package}"
	echo "kernel_commit=$(git -C "${kernel_source}" rev-parse HEAD)"
	echo "pmbootstrap_commit=$(git -C "${pmbootstrap_dir}" rev-parse HEAD)"
	echo "pmaports_commit=$(git -C "${pmaports_dir}" rev-parse HEAD)"
	echo "runner_os=${RUNNER_OS:-unknown}"
	echo "runner_arch=${RUNNER_ARCH:-unknown}"
} >"${output_dir}/BUILD-MANIFEST.txt"

(
	cd "${output_dir}"
	find . -type f ! -name SHA256SUMS -print0 \
		| sort -z \
		| xargs -0 sha256sum
) >"${output_dir}/SHA256SUMS"

echo "Final disk use:"
df -h /

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
	{
		echo "## Ocean postmarketOS build"
		echo
		echo "- Mode: \`${build_mode}\`"
		echo "- Kernel package: \`${kernel_package}\`"
		echo "- Device: \`${device}\`"
		echo "- Artifact files:"
		find "${output_dir}" -type f -printf '  - `%P`\n' | sort
	} >>"${GITHUB_STEP_SUMMARY}"
fi
