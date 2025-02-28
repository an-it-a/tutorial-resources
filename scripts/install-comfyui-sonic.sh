git clone https://github.com/comfyanonymous/ComfyUI.git
cd ComfyUI
pip install -r requirements.txt
cd custom_nodes
git clone https://github.com/smthemex/ComfyUI_Sonic.git
cd ComfyUI_Sonic
pip install -r requirements.txt
cd ..
git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git
cd ComfyUI-VideoHelperSuite
pip install -r requirements.txt
cd ../../models
mkdir sonic
cd sonic
wget "https://huggingface.co/LeonJoe13/Sonic/resolve/main/Sonic/audio2bucket.pth?download=true" --content-disposition
wget "https://huggingface.co/LeonJoe13/Sonic/resolve/main/Sonic/audio2token.pth?download=true" --content-disposition
wget "https://huggingface.co/LeonJoe13/Sonic/resolve/main/Sonic/unet.pth?download=true" --content-disposition
wget "https://huggingface.co/LeonJoe13/Sonic/resolve/main/yoloface_v5m.pt?download=true" --content-disposition
mkdir RIFE
cd RIFE
wget "https://huggingface.co/LeonJoe13/Sonic/resolve/main/RIFE/flownet.pkl?download=true" --content-disposition
cd ..
mkdir whisper-tiny
cd whisper-tiny
wget "https://huggingface.co/openai/whisper-tiny/resolve/main/config.json?download=true" --content-disposition
wget "https://huggingface.co/openai/whisper-tiny/resolve/main/model.safetensors?download=true" --content-disposition
wget "https://huggingface.co/openai/whisper-tiny/resolve/main/preprocessor_config.json?download=true" --content-disposition
cd ../../checkpoints
wget "https://huggingface.co/moonshotmillion/svd_1.1_xt/resolve/main/svd_xt_1_1.safetensors?download=true" --content-disposition
pip install opencv-python