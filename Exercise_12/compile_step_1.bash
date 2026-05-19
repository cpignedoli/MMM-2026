
#!/usr/bin/env bash
set -euo pipefail

ENV_NAME=dp-train
YAML_FILE=dp-train.yml

echo "=== [1/6] Writing ${YAML_FILE} ==="
cat > ${YAML_FILE} <<'EOF'
name: dp-train
channels:
  - conda-forge
dependencies:
  - python=3.9
  - pip
  - numpy<2
  - protobuf<5
  - cmake
  - ninja
EOF

echo "=== [2/6] Creating conda environment ${ENV_NAME} ==="
conda env remove -n ${ENV_NAME} -y || true
conda env create -f ${YAML_FILE}

echo "=== [3/6] Activating environment and cleaning variables ==="
source "$(conda info --base)/etc/profile.d/conda.sh"
set +u  # conda activation scripts use unbound variables
conda activate ${ENV_NAME}
set -u

export PYTHONNOUSERSITE=1
unset PYTHONPATH || true
unset LD_LIBRARY_PATH || true

echo "=== [4/6] Installing pip packages ==="
pip install --upgrade pip
pip install tensorflow==2.18.1 gast wrapt astunparse

echo "=== [5/6] Checking TensorFlow runtime ==="
python - <<'EOF'
import tensorflow as tf
print("TensorFlow runtime:", tf.__version__)
assert tf.__version__.startswith("2.18"), "TensorFlow is not 2.18.x"
EOF

echo "=== [5/6] Installing deepmd-kit compiled against TF 2.18 ==="
pip uninstall -y deepmd-kit || true
# --no-binary forces compilation from source to ensure compatibility with TF 2.18.1
pip install --no-binary deepmd-kit deepmd-kit

echo "=== [6/6] Final check ==="
python - <<'EOF'
import tensorflow as tf
import deepmd
print("TensorFlow runtime:", tf.__version__)
print("DeepMD version:", deepmd.__version__)
assert tf.__version__.startswith("2.18"), "Wrong TF runtime"
EOF

echo "=== SETUP COMPLETED SUCCESSFULLY ✅ ==="
