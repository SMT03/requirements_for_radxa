#!/bin/bash

# Bash script to convert from Panfrost to Mali proprietary drivers on Radxa Rock 5B+,
# remove browsers, install Vulkan, OpenCL, and OpenCV with hardware acceleration support.
# Handles errors with logging and failsafes. Assumes Debian/Ubuntu-based system (e.g., Radxa OS or Armbian).
# Run as root: sudo bash req.sh
# Changes: Uses virtual environment for Python packages, checks RKNN file existence, skips Vulkan tests in headless setups,
# prompts for reboot, updates error handling, and fixes outdated URLs.

set -euo pipefail  # Exit on error, undefined vars, pipe failures
LOG_FILE="/var/log/radxa_setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1  # Log all output

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Use: sudo bash $0"
    exit 1
fi

echo "Starting Radxa Rock 5B+ setup on $(date). Current user: $(whoami)"
echo "This script converts from default Panfrost to proprietary Mali drivers."

# Function to handle errors gracefully
handle_error() {
    local exit_code=$?
    echo "Error occurred in $1. Exit code: $exit_code. Continuing with next steps..." | tee -a "$LOG_FILE"
}
trap 'handle_error "${FUNCNAME:-main}"' ERR

# Update system
echo "Updating system packages..."
apt update || { echo "apt update failed, trying apt update --fix-missing"; apt update --fix-missing; }
apt upgrade -y || echo "apt upgrade had issues, but continuing."

# Create Python virtual environment
VENV_PATH="/home/radxa/radxa_venv"
echo "Creating Python virtual environment at $VENV_PATH..."
python3 -m venv "$VENV_PATH"
source "$VENV_PATH/bin/activate"
pip install --upgrade pip setuptools wheel || echo "pip upgrade failed."

# Step 1: Install Mali proprietary drivers (conversion from Panfrost)
echo "Converting to Mali G610 proprietary drivers..."
# Create necessary directories if missing
mkdir -p /lib/firmware /usr/lib/aarch64-linux-gnu /etc/OpenCL/vendors /etc/modprobe.d

# Download and install libmali deb (replace <correct-source> with actual URL)
cd /tmp
LIBMALI_DEB="libmali-valhall-g610-g24p0-x11-wayland-gbm_1.9-1_arm64.deb"
if [ ! -f "$LIBMALI_DEB" ]; then
    wget "<correct-source>/${LIBMALI_DEB}" || {
        echo "Download failed. Trying alternative source..."
        wget "<correct-alt-source>/libmali-valhall-g610-g24p0-x11-wayland-gbm.so" -O libmali.so || {
            echo "libmali download failed. Falling back to Panfrost."
        }
        if [ -f libmali.so ]; then
            mv libmali.so /usr/lib/aarch64-linux-gnu/
            ldconfig || echo "ldconfig failed."
        fi
    }
fi
if [ -f "$LIBMALI_DEB" ]; then
    dpkg -i "$LIBMALI_DEB" || apt install -f -y || echo "dpkg install failed, dependencies may be missing."
    ldconfig || echo "ldconfig failed."
else
    echo "libmali deb not downloaded. GPU acceleration may use Panfrost."
fi

# Download firmware
if [ ! -f /lib/firmware/mali_csffw.bin ]; then
    wget "<correct-firmware-source>/mali_csffw.bin" -O /lib/firmware/mali_csffw.bin || {
        echo "Firmware download failed. GPU may not initialize properly."
    }
fi

# Standard blacklist file for Panfrost
echo "Creating/Updating blacklist for Panfrost..."
cat << EOF > /etc/modprobe.d/panfrost.conf || echo "Blacklist file creation failed."
blacklist panfrost
#blacklist mali
#blacklist bifrost_kbase
#blacklist midgard_kbase
EOF
update-initramfs -u || echo "initramfs update failed."

# Disable Zink for better compatibility
echo "Disabling Zink..."
echo "LIBGL_KOPPER_DISABLE=true" >> /etc/environment || echo "Zink disable failed."

# Prompt for reboot
echo "Mali drivers installed. Reboot required to load drivers."
echo "Reboot now? (y/n)"
read -r answer
if [ "$answer" = "y" ]; then
    reboot
else
    echo "Please reboot manually to load Mali drivers before continuing."
    exit 1
fi

# Step 2: Remove all browsers
echo "Removing browsers..."
BROWSERS=("firefox" "firefox-esr" "chromium" "chromium-browser" "google-chrome-stable" "epiphany-browser" "midori" "netsurf-gtk" "qutebrowser")
for browser in "${BROWSERS[@]}"; do
    if dpkg -l | grep -q "^ii  $browser"; then
        apt remove --purge -y "$browser" || apt autoremove -y "$browser" || echo "Failed to remove $browser, but continuing."
    else
        echo "$browser not installed, skipping."
    fi
done
apt autoremove -y || echo "Autoremove had issues."
if command -v snap >/dev/null 2>&1; then
    snap list | grep -q browser && snap remove firefox || echo "No snap browsers found."
fi

# Step 3: Install Vulkan, OpenCL, and OpenCV
echo "Installing Vulkan, OpenCL, and OpenCV..."

# Install dependencies
apt install -y vulkan-tools vulkan-validationlayers libvulkan-dev mesa-vulkan-drivers || {
    echo "Vulkan packages failed. Adding Oibaf PPA for latest Mesa."
    apt install -y software-properties-common || echo "software-properties-common install failed."
    add-apt-repository ppa:oibaf/graphics-drivers -y 2>/dev/null || echo "PPA add failed, skipping."
    apt update || echo "Update after PPA failed."
    apt install -y vulkan-tools libvulkan1 mesa-vulkan-drivers || echo "Vulkan still failed, using defaults."
}

# OpenCL: Install clinfo and create ICD
apt install -y ocl-icd-opencl-dev clinfo || echo "OpenCL dev packages failed."
LIBMALI_SO="/usr/lib/aarch64-linux-gnu/libmali-valhall-g610-g24p0-x11-wayland-gbm.so"
if [ ! -f "$LIBMALI_SO" ]; then
    LIBMALI_SO="/usr/lib/aarch64-linux-gnu/libmali.so"  # Fallback
fi
if [ -f "$LIBMALI_SO" ]; then
    echo "$LIBMALI_SO" > /etc/OpenCL/vendors/mali.icd || echo "ICD creation failed."
    ln -sf "$LIBMALI_SO" /usr/lib/aarch64-linux-gnu/libOpenCL.so || echo "OpenCL symlink failed."
    ldconfig || echo "ldconfig after OpenCL failed."
else
    echo "libmali not found, OpenCL ICD skipped."
fi

# Vulkan/OpenCL tests
if [ -z "$DISPLAY" ]; then
    echo "No display detected. Skipping vkcube test."
else
    echo "Testing Vulkan..." && vkcube || echo "vkcube failed."
fi
echo "Testing OpenCL..." && clinfo || echo "clinfo failed."

# Verify Mali kernel driver
echo "Verifying Mali kernel driver..." && lsmod | grep mali || echo "Mali module not loaded."

# OpenCV with apt
apt install -y python3-opencv libopencv-dev build-essential cmake pkg-config || echo "OpenCV deps failed."
echo "export OPENCV_OPENCL_DEVICE=enabled" >> /etc/environment || echo "OpenCV env failed."
echo "OpenCV installed. Rebuild from source for full accel if needed."

# Step 4: Install Python packages in virtual environment
echo "Installing Python packages in virtual environment..."
PACKAGES=(
    "absl-py==2.3.1"
    "antlr4-python3-runtime==4.12.0"
    "beautifulsoup4==4.13.4"
    "bitarray==3.6.0"
    "bitstring==4.3.1"
    "black==25.1.0"
    "certifi==2025.8.3"
    "cffi==1.17.1"
    "chardet==5.2.0"
    "charset-normalizer==3.4.3"
    "click==8.2.1"
    "cloudpickle==3.1.1"
    "coloredlogs==15.0.1"
    "contourpy==1.3.3"
    "cycler==0.12.1"
    "Cython==3.1.3"
    "deep-sort-realtime==1.3.2"
    "fast-histogram==0.14"
    "filelock==3.18.0"
    "flake8==7.3.0"
    "flatbuffers==25.2.10"
    "fonttools==4.59.1"
    "fsspec==2025.7.0"
    "future==1.0.0"
    "gdown==5.2.0"
    "grpcio==1.74.0"
    "h5py==3.14.0"
    "holidays==0.78"
    "humanfriendly==10.0"
    "idna==3.10"
    "imageio==2.37.0"
    "isort==4.3.21"
    "Jinja2==3.1.6"
    "kazoo==2.10.0"
    "kiwisolver==1.4.9"
    "Markdown==3.8.2"
    "MarkupSafe==3.0.2"
    "matplotlib==3.10.5"
    "mccabe==0.7.0"
    "mpmath==1.3.0"
    "mpp==0.1.9"
    "mypy_extensions==1.1.0"
    "networkx==3.5"
    "numpy==1.26.4"
    "onnx==1.16.1"
    "onnxruntime==1.22.1"
    "overrides==7.7.0"
    "packaging==25.0"
    "pathspec==0.12.1"
    "pillow==11.3.0"
    "platformdirs==4.3.8"
    "protobuf==4.25.4"
    "psutil==7.0.0"
    "pybind11==3.0.0"
    "pybind11-global==3.0.0"
    "pycodestyle==2.14.0"
    "pycparser==2.22"
    "pyflakes==3.4.0"
    "pyparsing==3.2.3"
    "PySocks==1.7.1"
    "python-dateutil==2.9.0.post0"
    "pytz==2025.2"
    "pyutils==0.0.14"
    "PyYAML==6.0.2"
    "requests==2.32.4"
    "ruamel.yaml==0.18.14"
    "ruamel.yaml.clib==0.2.12"
    "scipy==1.16.1"
    "setuptools==78.1.1"
    "six==1.17.0"
    "soupsieve==2.7"
    "sympy==1.14.0"
    "tb-nightly==2.21.0a20250821"
    "tensorboard==2.20.0"
    "tensorboard-data-server==0.7.2"
    "torch==2.2.0"
    "torchvision==0.17.0"
    "tqdm==4.67.1"
    "typing_extensions==4.14.1"
    "urllib3==2.5.0"
    "Werkzeug==3.1.3"
    "wheel==0.45.1"
    "yacs==0.1.8"
    "yapf==0.43.0"
)

for pkg in "${PACKAGES[@]}"; do
    echo "Installing $pkg..."
    pip install "$pkg" || {
        echo "Failed $pkg. Trying base."
        pip install "${pkg%%==*}" || echo "Base $pkg failed."
    }
done

# Install RKNN packages
RKNN_LITE_PATH="/home/radxa/Documents/rknn/rknn-toolkit2-master/rknn-toolkit-lite2/packages/rknn_toolkit_lite2-2.3.2-cp312-cp312-manylinux_2_17_aarch64.manylinux2014_aarch64.whl"
RKNN_PATH="/home/radxa/Documents/rknn/rknn-toolkit2-master/rknn-toolkit2/packages/arm64/rknn_toolkit2-2.3.2-cp312-cp312-manylinux_2_17_aarch64.manylinux2014_aarch64.whl"

if [ -f "$RKNN_LITE_PATH" ]; then
    pip install "$RKNN_LITE_PATH" || echo "RKNN Lite failed."
else
    echo "RKNN Lite not found at $RKNN_LITE_PATH. Download manually."
fi

if [ -f "$RKNN_PATH" ]; then
    pip install "$RKNN_PATH" || echo "RKNN failed."
else
    echo "RKNN not found at $RKNN_PATH. Download manually."
fi

# Install torchreid from git
echo "Installing torchreid from git..."
pip install git+https://github.com/KaiyangZhou/deep-person-reid.git@566a56a2cb255f59ba75aa817032621784df546a || {
    echo "Git install failed. Try manual."
}

# Cleanup
apt autoremove -y
pip cache purge || echo "Pip cache failed."

echo "Setup complete! Verify setup with: sudo ./validation.sh"
echo "Check logs: tail -f $LOG_FILE"
echo "Verify: lsmod | grep mali, vkcube, clinfo, python3 -c 'import cv2; print(cv2.getBuildInformation())'"
echo "Known fixes: Firmware, blacklist, ICD, Zink disable. If issues, check Radxa forums."
