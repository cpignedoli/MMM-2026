
#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Configuration
# ============================================================
export MAKEFLAGS="-j2"

DEEPMD_VERSION="v2.2.11"
LAMMPS_TAG="stable_2Aug2023_update4"
LAMMPS_VER_NUM="20230802"
LAMMPS_VER_STR="2 Aug 2023"
TF_VERSION="2.15.1"
INSTALL_PREFIX="$HOME/deepmd-kit"
VENV="$HOME/venv-deepmd"
TF_PATH="$VENV/lib/python3.9/site-packages/tensorflow"

# ============================================================
# [1/6] Python venv and TensorFlow
# ============================================================
echo "=== [1/6] Creating venv and installing TensorFlow ==="
python3 -m venv "$VENV"
source "$VENV/bin/activate"
pip install --upgrade pip
pip install --upgrade cmake
pip install tensorflow==${TF_VERSION}

# Check that TF C++ libs are present (not included on all platforms)
ls "$TF_PATH/libtensorflow_cc.so.2"        || { echo "ERROR: libtensorflow_cc.so.2 not found";        exit 1; }
ls "$TF_PATH/libtensorflow_framework.so.2" || { echo "ERROR: libtensorflow_framework.so.2 not found"; exit 1; }

# Create symlinks without version suffix so the linker can find them
# (needed on aarch64 where the linker looks for .so not .so.2)
ln -sf "$TF_PATH/libtensorflow_cc.so.2"        "$TF_PATH/libtensorflow_cc.so"
ln -sf "$TF_PATH/libtensorflow_framework.so.2" "$TF_PATH/libtensorflow_framework.so"
echo "TF libs OK"

# ============================================================
# [2/6] Build DeePMD-kit from source
# ============================================================
echo "=== [2/6] Building DeePMD-kit ==="
cd "$HOME"
rm -rf deepmd-kit
git clone https://github.com/deepmodeling/deepmd-kit.git
cd deepmd-kit
git checkout ${DEEPMD_VERSION}
cd source
mkdir build && cd build

# Point cmake explicitly to the TF libs inside the venv
cmake \
  -DUSE_TF_PYTHON_LIBS=TRUE \
  -DTENSORFLOW_ROOT="$TF_PATH" \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  ..

make
make install
make lammps  # generates the USER-DEEPMD plugin directory for LAMMPS

ls "$INSTALL_PREFIX/lib/libdeepmd_c.so" || { echo "ERROR: libdeepmd_c.so not found"; exit 1; }
echo "DeePMD libs OK"

# ============================================================
# [3/6] Clone LAMMPS and fix version.h
# ============================================================
echo "=== [3/6] Cloning LAMMPS ==="
cd "$HOME"
rm -rf lammps
git clone https://github.com/lammps/lammps.git
cd lammps
git checkout ${LAMMPS_TAG}

# Write version.h AFTER checkout — git would overwrite it otherwise
cat > src/version.h <<EOF
#define LAMMPS_VERSION_NUMBER ${LAMMPS_VER_NUM}
#define LAMMPS_VERSION "${LAMMPS_VER_STR}"
EOF

# ============================================================
# [4/6] Copy USER-DEEPMD plugin and build PLUMED
# ============================================================
echo "=== [4/6] Copying USER-DEEPMD and building PLUMED ==="
cp -r "$HOME/deepmd-kit/source/build/USER-DEEPMD" "$HOME/lammps/src/"
ls "$HOME/lammps/src/USER-DEEPMD/pair_deepmd.cpp" || { echo "ERROR: USER-DEEPMD missing"; exit 1; }

# Copy all USER-DEEPMD source files directly into src/
# (Install.sh is unreliable across platforms — do it manually)
cp "$HOME/lammps/src/USER-DEEPMD/"*.cpp "$HOME/lammps/src/"
cp "$HOME/lammps/src/USER-DEEPMD/"*.h   "$HOME/lammps/src/"

# Clean any previous PLUMED state and rebuild from scratch
cd "$HOME/lammps/src"
make no-plumed || true
rm -rf ../lib/plumed
cd "$HOME/lammps"
git checkout -- lib/plumed
cd src

# Temporarily unset MAKEFLAGS — PLUMED's build system ignores it and may break
SAVED_MAKEFLAGS="$MAKEFLAGS"
unset MAKEFLAGS
make lib-plumed args="-b" CC=gcc CXX=g++ MAKE="make -j2"
export MAKEFLAGS="$SAVED_MAKEFLAGS"

ls ../lib/plumed/Makefile.lammps || { echo "ERROR: PLUMED build failed"; exit 1; }

# ============================================================
# [5/6] Patch Makefile.serial and enable packages
# ============================================================
echo "=== [5/6] Patching Makefile and enabling packages ==="

# Inject DeePMD and TF include/library paths into the serial Makefile
# Explicit -ltensorflow_cc and -ltensorflow_framework needed on aarch64
sed -i "s|^CCFLAGS =.*|CCFLAGS = -g -O3 -std=c++11 -I$TF_PATH/include -I$INSTALL_PREFIX/include|" \
  "$HOME/lammps/src/MAKE/Makefile.serial"

sed -i "s|^LIB =.*|LIB = -L$TF_PATH -L$INSTALL_PREFIX/lib -ldeepmd_c -ltensorflow_cc -ltensorflow_framework -Wl,-rpath=$TF_PATH -Wl,-rpath=$INSTALL_PREFIX/lib|" \
  "$HOME/lammps/src/MAKE/Makefile.serial"

# Verify the patch
grep -E "^CCFLAGS|^LIB" "$HOME/lammps/src/MAKE/Makefile.serial"

cd "$HOME/lammps/src"
make yes-plumed
make yes-kspace
make yes-extra-fix
make yes-user-deepmd
make yes-reaxff
make yes-molecule
make yes-rigid
make yes-manybody

# Confirm critical packages are enabled before compiling
make ps | grep -E "USER-DEEPMD|PLUMED"

# ============================================================
# [6/6] Compile LAMMPS and install
# ============================================================
echo "=== [6/6] Compiling LAMMPS ==="
make serial

ls "$HOME/lammps/src/lmp_serial" || { echo "ERROR: lmp_serial not built"; exit 1; }
chmod 755 "$HOME/lammps/src/lmp_serial"

# Copy binary into the dp-train conda environment
set +u
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate dp-train
set -u
cp "$HOME/lammps/src/lmp_serial" "$HOME/.conda/envs/dp-train/bin/lmp_dp"
chmod 755 "$HOME/.conda/envs/dp-train/bin/lmp_dp"

echo "=== Final check ==="
lmp_dp -h | grep -i deepmd && echo "deepmd ✅" || echo "deepmd ❌"
lmp_dp -h | grep -i plumed && echo "plumed ✅" || echo "plumed ❌"
lmp_dp -h | grep -i reax   && echo "reaxff ✅" || echo "reaxff ❌"

echo "=== BUILD COMPLETED SUCCESSFULLY ✅ ==="
