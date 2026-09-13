#!/bin/bash
set -e
# ============================================================
# Script de renderizacao de video "faceless explicativo" (formato Short,
# vertical 1080x1920, ~45-60s) -- usado por MindBlown Daily e Wealth Signals.
# Cada frase do roteiro tem sua PROPRIA imagem (Ken Burns) + legenda estilo
# karaoke sincronizada por palavra (mesma tecnica ja provada no projeto
# Dormindo com Jesus, so que aqui e fala normal em ingles, nao canto -- a
# transcricao do Whisper fica bem mais precisa e nao precisa dos ajustes de
# atraso/VAD sensivel que a musica cantada exigia).
#
# Variaveis esperadas:
#   AUDIO_URL        -> URL do mp3 da narracao (TTS, gerado no n8n)
#   IMAGE_URLS_JSON  -> ex: '["https://images.pexels.com/...1.jpg", "...2.jpg"]' (uma por frase/segmento)
#   TITULO           -> titulo do video (usado na thumbnail)
# ============================================================
WORKDIR="render_work"
rm -rf "$WORKDIR" && mkdir -p "$WORKDIR"
cd "$WORKDIR"

FONT="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
ASS_FONT_NAME="DejaVu Sans"

echo "== Instalando Pillow (thumbnail) e faster-whisper (legenda) =="
pip install pillow faster-whisper --break-system-packages --quiet 2>/dev/null || pip install pillow faster-whisper --quiet

# Baixa um arquivo com retry + validacao real de conteudo (nao so "sucesso HTTP").
# Mesma logica ja provada no Dormindo com Jesus: sem --fail o curl salva pagina
# de erro/arquivo vazio como se fosse sucesso; e mesmo com --fail, o CDN publico
# do GitHub (raw.githubusercontent.com) pode nao ter propagado ainda um arquivo
# recem-commitado -- nesse caso cai pro fallback via api.github.com/.../contents/,
# que reflete o commit mais recente na hora, sem lag de CDN.
baixar_com_retry() {
  local url="$1"
  local destino="$2"
  local tipo="${3:-}"
  local tentativas=6
  local tentativa=1
  while [ "$tentativa" -le "$tentativas" ]; do
    if curl -sL --fail --max-time 30 -o "$destino" "$url" && [ -s "$destino" ]; then
      if [ "$tipo" = "img" ]; then
        local assinatura
        assinatura=$(od -An -tx1 -N4 "$destino" 2>/dev/null | tr -d ' \n')
        # aceita JPEG (ffd8ffe...) ou PNG (89504e47)
        case "$assinatura" in
          ffd8ff*|89504e47*) : ;;
          *)
            echo "  Aviso: arquivo baixado nao e imagem valida (tentativa $tentativa/$tentativas): $url"
            tentativa=$((tentativa + 1)); sleep 4; continue
            ;;
        esac
      fi
      return 0
    fi
    echo "  Aviso: falha ao baixar (tentativa $tentativa/$tentativas): $url"
    tentativa=$((tentativa + 1))
    sleep 4
  done
  if [[ "$url" == https://raw.githubusercontent.com/* ]] && [ -n "${GH_TOKEN:-}" ]; then
    echo "  Tentando via api.github.com (sem lag de CDN)..."
    local api_url
    api_url=$(echo "$url" | sed -E 's#https://raw.githubusercontent.com/([^/]+)/([^/]+)/([^/]+)/(.*)#https://api.github.com/repos/\1/\2/contents/\4?ref=\3#')
    if curl -sL --fail --max-time 30 -H "Authorization: token $GH_TOKEN" -H "Accept: application/vnd.github.raw" -o "$destino" "$api_url" && [ -s "$destino" ]; then
      return 0
    fi
  fi
  echo "ERRO FATAL: nao foi possivel baixar apos $tentativas tentativas: $url"
  exit 1
}

echo "== Baixando narracao =="
baixar_com_retry "$AUDIO_URL" narracao.mp3
DURACAO_TOTAL=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 narracao.mp3)
echo "Duracao da narracao: ${DURACAO_TOTAL}s"

echo "== Baixando imagens =="
echo "$IMAGE_URLS_JSON" | jq -r '.[]' | nl -w2 -nrz | while read -r idx url; do
  baixar_com_retry "$url" "img_${idx}.jpg" img
done
NUM_IMAGENS=$(echo "$IMAGE_URLS_JSON" | jq 'length')
echo "Total de imagens: $NUM_IMAGENS"

echo "== Transcrevendo narracao com faster-whisper (timestamps por palavra, ingles) =="
cat > transcrever.py << 'PYEOF'
import json
from faster_whisper import WhisperModel

model = WhisperModel("small", device="cpu", compute_type="int8")
segments, info = model.transcribe("narracao.mp3", word_timestamps=True, language="en")

palavras = []
for seg in segments:
    for w in seg.words:
        texto = w.word.strip()
        if texto:
            palavras.append({"start": w.start, "end": w.end, "text": texto})

with open("palavras.json", "w", encoding="utf-8") as f:
    json.dump(palavras, f, ensure_ascii=False)
print(f"{len(palavras)} palavras transcritas")
PYEOF
python3 transcrever.py

echo "== Gerando legenda karaoke (.ass) =="
cat > gerar_ass.py << 'PYEOF'
import json

with open("palavras.json", encoding="utf-8") as f:
    palavras = json.load(f)

def fmt_ass_time(segundos):
    h = int(segundos // 3600)
    m = int((segundos % 3600) // 60)
    s = segundos % 60
    return f"{h}:{m:02d}:{s:05.2f}"

HEADER = """[Script Info]
ScriptType: v4.00+
PlayResX: 1080
PlayResY: 1920
WrapStyle: 0
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Karaoke,DejaVu Sans,64,&H00FFFFFF,&H00FFFFFF,&H00000000,&H64000000,1,0,0,0,100,100,0,0,1,5,2,2,60,60,700,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""

PALETA = ["&H1ED6FF&", "&H27B7FF&", "&H4FD16C&", "&HF2C40E&", "&HE383C5&"]

linhas_evento = []
grupo = []
ultimo_fim = None
indice_cor = [0]

def emitir(grupo_palavras):
    if not grupo_palavras:
        return
    inicio = grupo_palavras[0]["start"]
    fim = grupo_palavras[-1]["end"]
    partes = ""
    for p in grupo_palavras:
        dur_cs = max(1, int(round((p["end"] - p["start"]) * 100)))
        cor = PALETA[indice_cor[0] % len(PALETA)]
        indice_cor[0] += 1
        partes += f"{{\\2c&HFFFFFF&\\1c{cor}\\k{dur_cs}}}{p['text']} "
    linhas_evento.append(f"Dialogue: 0,{fmt_ass_time(inicio)},{fmt_ass_time(fim)},Karaoke,,0,0,0,,{partes.strip()}")

for p in palavras:
    if ultimo_fim is not None and (p["start"] - ultimo_fim) > 0.5 and grupo:
        emitir(grupo)
        grupo = []
    grupo.append(p)
    ultimo_fim = p["end"]
    if len(grupo) >= 5:
        emitir(grupo)
        grupo = []
if grupo:
    emitir(grupo)

with open("legendas.ass", "w", encoding="utf-8") as f:
    f.write(HEADER)
    f.write("\n".join(linhas_evento))
print(f"{len(linhas_evento)} linhas de legenda geradas")
PYEOF
python3 gerar_ass.py

echo "== Gerando segmentos de imagem (Ken Burns, vertical 1080x1920) =="
DURACAO_POR_IMAGEM=$(echo "$DURACAO_TOTAL / $NUM_IMAGENS" | bc -l)
echo "Duracao por imagem: ${DURACAO_POR_IMAGEM}s"

for ((i=1; i<=NUM_IMAGENS; i++)); do
  IDX=$(printf "%02d" "$i")
  ffmpeg -y -loop 1 -i "img_${IDX}.jpg" -t "$DURACAO_POR_IMAGEM" \
    -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,zoompan=z='min(zoom+0.0015,1.3)':d=$(echo "$DURACAO_POR_IMAGEM * 25" | bc | cut -d. -f1):s=1080x1920:fps=25" \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p "seg_${IDX}.mp4" -loglevel error
done

echo "== Concatenando segmentos =="
> concat_list.txt
for ((i=1; i<=NUM_IMAGENS; i++)); do
  IDX=$(printf "%02d" "$i")
  echo "file '$(pwd)/seg_${IDX}.mp4'" >> concat_list.txt
done
ffmpeg -y -f concat -safe 0 -i concat_list.txt -c copy video_sem_audio.mp4 -loglevel error

echo "== Juntando audio, video e legenda =="
ffmpeg -y -i video_sem_audio.mp4 -i narracao.mp3 \
  -vf "ass=legendas.ass:fontsdir=/usr/share/fonts" \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -shortest video_final.mp4 -loglevel error

echo "== Concluido =="
ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 video_final.mp4
ls -la video_final.mp4

echo "== Gerando thumbnail =="
cat > make_thumbnail.py << 'PYEOF'
import sys, textwrap
from PIL import Image, ImageDraw, ImageFont, ImageFilter

def main():
    titulo, out_path = sys.argv[1], sys.argv[2]
    base = Image.open("img_01.jpg").convert("RGB").resize((1080, 1920))
    base = base.filter(ImageFilter.GaussianBlur(3))
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 90)
    linhas = textwrap.wrap(titulo.upper(), width=14)
    y = 1920 - (len(linhas) * 110) - 140
    for linha in linhas:
        bbox = d.textbbox((0, 0), linha, font=font)
        w = bbox[2] - bbox[0]
        x = (1080 - w) / 2
        d.rectangle([x - 20, y - 10, x + w + 20, y + 100], fill=(230, 30, 38, 220))
        d.text((x, y), linha, font=font, fill=(255, 255, 255, 255))
        y += 110
    base.convert("RGBA")
    combined = Image.alpha_composite(base.convert("RGBA"), overlay)
    combined.convert("RGB").save(out_path, quality=92)

if __name__ == "__main__":
    main()
PYEOF
python3 make_thumbnail.py "$TITULO" thumbnail.jpg
echo "== Thumbnail gerada =="
ls -la thumbnail.jpg
