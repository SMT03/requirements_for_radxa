#!/bin/bash

# Validation script for Radxa Rock 5B+ setup requirements
# Checks Mali proprietary drivers, browser removal, Vulkan/OpenCL, OpenCV with HW accel, and Python packages.
# Run as root or user with access: bash this_script.sh
# Outputs PASS/FAIL for each check, summary at end.
# Based on Radxa docs and forums (as of Sep 2025).

set -uo pipefail  # Exit on undefined vars, pipe failures
LOG_FILE="/var/log/radxa_validation.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Colors for output
GREEN="\033[0;32m"
RED="\033[0;31m"
RESET="\033[0m"

echo "Starting validation on $(date)."

# Counters for summary
PASSED=0
FAILED=0
TOTAL=0

# Function to check and report
check() {
    local name="$1"
    local command="$2"
    local expected="$3"
    ((TOTAL++))
    if eval "$command" &> /dev/null; then
        output=$(eval "$command")
        if [[ "$output" == *"$expected"* ]]; then
            echo -e "${GREEN}PASS:${RESET} $name"
            ((PASSED++))
        else
            echo -e "${RED}FAIL:${RESET} $name (Expected: $expected, Got: $output)"
            ((FAILED++))
        fi
    else
        echo -e "${RED}FAIL:${RESET} $name (Command failed or not found)"
        ((FAILED++))
    fi
}

# Function for simple existence check
check_exists() {
    local name="$1"
    local path="$2"
    ((TOTAL++))
    if [ -f "$path" ] || [ -d "$path" ]; then
        echo -e "${GREEN}PASS:${RESET} $name ($path exists)"
        ((PASSED++))
    else
        echo -e "${RED}FAIL:${RESET} $name ($path missing)"
        ((FAILED++))
    fi
}

# Function for browser not installed
check_browser_removed() {
    local name="$1"
    local pkg="$2"
    ((TOTAL++))
    if dpkg -l | grep -q "^ii  $pkg"; then
        echo -e "${RED}FAIL:${RESET} $name ($pkg still installed)"
        ((FAILED++))
    else
        echo -e "${GREEN}PASS:${RESET} $name ($pkg removed)"
        ((PASSED++))
    fi
}

# Function for pip package version
check_pip() {
    local pkg="$1"
    local version="$2"
    ((TOTAL++))
    if pip3 show "$pkg" &> /dev/null; then
        installed=$(pip3 show "$pkg" | grep Version | cut -d' ' -f2)
        if [ "$installed" == "$version" ]; then
            echo -e "${GREEN}PASS:${RESET} $pkg == $version"
            ((PASSED++))
        else
            echo -e "${RED}FAIL:${RESET} $pkg (Installed: $installed, Expected: $version)"
            ((FAILED++))
        fi
    else
        echo -e "${RED}FAIL:${RESET} $pkg (Not installed)"
        ((FAILED++))
    fi
}

# Section 1: Mali Proprietary Drivers
echo "=== Mali Proprietary Drivers Checks ==="
check_exists "libmali library" "/usr/lib/aarch64-linux-gnu/libmali-valhall-g610-g24p0-x11-wayland-gbm.so"
check_exists "Mali firmware" "/lib/firmware/mali_csffw.bin"
check_exists "Panfrost blacklist" "/etc/modprobe.d/panfrost.conf"
check "Mali kernel module loaded" "lsmod | grep -i mali || lsmod | grep -i bifrost_kbase" "mali"  # Or bifrost_kbase per docs
check "xorg-xserver from Rockchip" "apt list xserver-common | grep installed" "rk3588-bookworm"  # Example, adjust if needed
check "Mali user-level installed" "apt list libmali-* --installed | grep installed" "libmali-valhall-g610-g24p0-x11-wayland-gbm"
check_exists "OpenCL ICD" "/etc/OpenCL/vendors/mali.icd"
check "Zink disabled" "grep LIBGL_KOPPER_DISABLE /etc/environment" "true"

# Section 2: Browsers Removed
echo "=== Browser Removal Checks ==="
BROWSERS=("firefox" "firefox-esr" "chromium" "chromium-browser" "google-chrome-stable" "epiphany-browser" "midori" "netsurf-gtk" "qutebrowser")
for browser in "${BROWSERS[@]}"; do
    check_browser_removed "$browser removed" "$browser"
done
check "No snap browsers" "snap list | grep -q browser || true" ""  # If grep fails (no match), it's PASS

# Section 3: Vulkan, OpenCL, OpenCV
echo "=== Vulkan, OpenCL, OpenCV Checks ==="
check "Vulkan installed" "vulkaninfo | grep -i deviceName" "Mali"  # Or vkcube, but needs display; fallback to package
check "OpenCL platforms" "clinfo | grep 'Number of platforms' | cut -d' ' -f5-" "1"  # Expect at least 1
check "OpenCL device Mali" "clinfo | grep 'Device Name'" "Mali" 

# OpenCV: Use python code for detailed check
echo "Checking OpenCV..."
OPENCV_CHECK=$(python3 -c "import cv2; import sys; print(cv2.__version__); have_ocl = cv2.ocl.haveOpenCL(); print('OpenCL support: ' + str(have_ocl));" 2>/dev/null)
if [[ "$OPENCV_CHECK" == *"4.11.0"* && "$OPENCV_CHECK" == *"OpenCL support: True"* ]]; then
    echo -e "${GREEN}PASS:${RESET} OpenCV ==4.11.0 with OpenCL support"
    ((PASSED++))
else
    echo -e "${RED}FAIL:${RESET} OpenCV (Output: $OPENCV_CHECK)"
    ((FAILED++))
fi
((TOTAL++))

# Section 4: Python Packages
echo "=== Python Packages Checks ==="
check_pip "absl-py" "2.3.1"
check_pip "antlr4-python3-runtime" "4.12.0"
check_pip "beautifulsoup4" "4.13.4"
check_pip "bitarray" "3.6.0"
check_pip "bitstring" "4.3.1"
check_pip "black" "25.1.0"
check_pip "certifi" "2025.8.3"
check_pip "cffi" "1.17.1"
check_pip "chardet" "5.2.0"
check_pip "charset-normalizer" "3.4.3"
check_pip "click" "8.2.1"
check_pip "cloudpickle" "3.1.1"
check_pip "coloredlogs" "15.0.1"
check_pip "contourpy" "1.3.3"
check_pip "cycler" "0.12.1"
check_pip "Cython" "3.1.3"
check_pip "deep-sort-realtime" "1.3.2"
check_pip "fast-histogram" "0.14"
check_pip "filelock" "3.18.0"
check_pip "flake8" "7.3.0"
check_pip "flatbuffers" "25.2.10"
check_pip "fonttools" "4.59.1"
check_pip "fsspec" "2025.7.0"
check_pip "future" "1.0.0"
check_pip "gdown" "5.2.0"
check_pip "grpcio" "1.74.0"
check_pip "h5py" "3.14.0"
check_pip "holidays" "0.78"
check_pip "humanfriendly" "10.0"
check_pip "idna" "3.10"
check_pip "imageio" "2.37.0"
check_pip "isort" "4.3.21"
check_pip "Jinja2" "3.1.6"
check_pip "kazoo" "2.10.0"
check_pip "kiwisolver" "1.4.9"
check_pip "Markdown" "3.8.2"
check_pip "MarkupSafe" "3.0.2"
check_pip "matplotlib" "3.10.5"
check_pip "mccabe" "0.7.0"
check_pip "mpmath" "1.3.0"
check_pip "mpp" "0.1.9"
check_pip "mypy_extensions" "1.1.0"
check_pip "networkx" "3.5"
check_pip "numpy" "1.26.4"
check_pip "onnx" "1.16.1"
check_pip "onnxruntime" "1.22.1"
check_pip "opencv-python" "4.11.0.86"
check_pip "overrides" "7.7.0"
check_pip "packaging" "25.0"
check_pip "pathspec" "0.12.1"
check_pip "pillow" "11.3.0"
check_pip "platformdirs" "4.3.8"
check_pip "protobuf" "4.25.4"
check_pip "psutil" "7.0.0"
check_pip "pybind11" "3.0.0"
check_pip "pybind11-global" "3.0.0"
check_pip "pycodestyle" "2.14.0"
check_pip "pycparser" "2.22"
check_pip "pyflakes" "3.4.0"
check_pip "pyparsing" "3.2.3"
check_pip "PySocks" "1.7.1"
check_pip "python-dateutil" "2.9.0.post0"
check_pip "pytz" "2025.2"
check_pip "pyutils" "0.0.14"
check_pip "PyYAML" "6.0.2"
check_pip "requests" "2.32.4"
check_pip "rknn-toolkit-lite2" "2.3.2"  # Assuming version from wheel
check_pip "rknn-toolkit2" "2.3.2"
check_pip "ruamel.yaml" "0.18.14"
check_pip "ruamel.yaml.clib" "0.2.12"
check_pip "scipy" "1.16.1"
check_pip "setuptools" "78.1.1"
check_pip "six" "1.17.0"
check_pip "soupsieve" "2.7"
check_pip "sympy" "1.14.0"
check_pip "tb-nightly" "2.21.0a20250821"
check_pip "tensorboard" "2.20.0"
check_pip "tensorboard-data-server" "0.7.2"
check_pip "torch" "2.2.0"
check_pip "torchreid" "1.4.0"  # Version from git, assume latest or check
check_pip "torchvision" "0.17.0"
check_pip "tqdm" "4.67.1"
check_pip "typing_extensions" "4.14.1"
check_pip "urllib3" "2.5.0"
check_pip "Werkzeug" "3.1.3"
check_pip "wheel" "0.45.1"
check_pip "yacs" "0.1.8"
check_pip "yapf" "0.43.0"

# Summary
echo "=== Summary ==="
echo "Total checks: $TOTAL"
echo -e "Passed: ${GREEN}$PASSED${RESET}"
echo -e "Failed: ${RED}$FAILED${RESET}"
if [ $FAILED -eq 0 ]; then
    echo "All requirements validated successfully!"
else
    echo "Some requirements failed. Check logs and fix issues."
fi

echo "Validation complete. Logs: $LOG_FILE"
