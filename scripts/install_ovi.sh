# Clone the repository
git clone https://github.com/character-ai/Ovi.git

cd Ovi

# Create and activate virtual environment
#virtualenv ovi-env
#source ovi-env/bin/activate

# Install PyTorch first
pip install torch==2.5.1 torchvision==0.20.1 torchaudio==2.5.1

# Install other dependencies
pip install -r requirements.txt

# Install Flash Attention
pip install flash_attn --no-build-isolation

python3 download_weights.py

wget -O "./ckpts/Ovi/model_fp8_e4m3fn.safetensors" "https://huggingface.co/rkfg/Ovi-fp8_quantized/resolve/main/model_fp8_e4m3fn.safetensors"
