#!/bin/bash
set -e
# ============================================================
# Script de renderizacao "faceless" formato LONGO (~10min, 16:9 horizontal,
# libera anuncio no meio a partir de 8min) + extracao de 2 Shorts verticais
# de dentro dele -- mesma arquitetura ja provada no Dormindo com Jesus
# (render_video_com_legenda.sh), adaptada pra narracao falada (nao cantada)
# sobre fotos de banco de imagens (Pexels) em vez de musica de fundo.
#
# Variaveis esperadas:
#   AUDIO_URLS_JSON  -> array de blocos SEQUENCIAIS da narracao (concatenar
#                       em ordem, NAO em loop -- juntos formam a narracao inteira)
#   IMAGE_URLS_JSON  -> array de URLs de imagens da Pexels (cicladas em loop
#                       ao longo do video, tipo ja funciona no Dormindo com Jesus)
#   TITULO           -> titulo do video (usado na thumbnail)
# ============================================================
WORKDIR="render_work"
rm -rf "$WORKDIR" && mkdir -p "$WORKDIR"
cd "$WORKDIR"
XFADE_DUR=0.5

FONT="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

echo "== Instalando Pillow (thumbnail) e faster-whisper (legenda) =="
pip install pillow faster-whisper --break-system-packages --quiet 2>/dev/null || pip install pillow faster-whisper --quiet

echo "== Aguardando 10s pra dar tempo do ultimo commit do n8n propagar na API do GitHub =="
sleep 10

# Baixa com retry + validacao real (mesma tecnica provada no Dormindo com Jesus):
# --fail detecta erro HTTP de verdade; se o CDN do GitHub ainda nao propagou um
# arquivo recem-commitado, cai pro fallback via api.github.com/.../contents/.
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
    local api_url
    api_url=$(echo "$url" | sed -E 's#https://raw.githubusercontent.com/([^/]+)/([^/]+)/([^/]+)/(.*)#https://api.github.com/repos/\1/\2/contents/\4?ref=\3#')
    local fallback_tentativa=1
    local fallback_max=10
    while [ "$fallback_tentativa" -le "$fallback_max" ]; do
      echo "  Tentando via api.github.com (sem lag de CDN) - tentativa $fallback_tentativa/$fallback_max..."
      if curl -sL --fail --max-time 30 -H "Authorization: token $GH_TOKEN" -H "Accept: application/vnd.github.raw" -o "$destino" "$api_url" && [ -s "$destino" ]; then
        if [ "$tipo" = "img" ]; then
          local assinatura2
          assinatura2=$(od -An -tx1 -N4 "$destino" 2>/dev/null | tr -d ' \n')
          case "$assinatura2" in
            ffd8ff*|89504e47*) return 0 ;;
          esac
        else
          return 0
        fi
      fi
      fallback_tentativa=$((fallback_tentativa + 1))
      sleep 6
    done
  fi
  echo "ERRO FATAL: nao foi possivel baixar apos $tentativas tentativas: $url"
  exit 1
}

echo "== Baixando blocos da narracao =="
echo "$AUDIO_URLS_JSON" | jq -r '.[]' | nl -w2 -nrz | while read -r idx url; do
  baixar_com_retry "$url" "audio_${idx}.mp3"
done

echo "== Concatenando blocos da narracao (ordem sequencial, sem loop) =="
> narracao_concat_list.txt
for f in $(ls audio_*.mp3 | sort); do
  echo "file '$(pwd)/$f'" >> narracao_concat_list.txt
done
ffmpeg -y -f concat -safe 0 -i narracao_concat_list.txt -c:a aac -ar 44100 narracao_completa.m4a -loglevel error
DURACAO_TOTAL=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 narracao_completa.m4a)
echo "Duracao total da narracao: ${DURACAO_TOTAL}s"

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
segments, info = model.transcribe("narracao_completa.m4a", word_timestamps=True, language="en")

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

echo "== Gerando legenda karaoke (.ass, formato 1920x1080) =="
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
PlayResX: 1920
PlayResY: 1080
WrapStyle: 0
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Karaoke,DejaVu Sans,64,&H00FFFFFF,&H00FFFFFF,&H00000000,&H64000000,1,0,0,0,100,100,0,0,1,5,2,2,80,80,90,1

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
    if len(grupo) >= 8:
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

echo "== Gerando segmentos de imagem (Ken Burns, 1920x1080, ciclando as imagens) =="
DURACAO_POR_IMAGEM_ALVO=20
CICLO_DURACAO=$(echo "$NUM_IMAGENS * $DURACAO_POR_IMAGEM_ALVO" | bc -l)
CICLOS=$(echo "($DURACAO_TOTAL / $CICLO_DURACAO) + 1" | bc)
NUM_SEGMENTOS=$(( NUM_IMAGENS * CICLOS ))
echo "Ciclos de imagens necessarios: $CICLOS (total de $NUM_SEGMENTOS trocas de cena)"

PERDA_TOTAL=$(echo "($NUM_SEGMENTOS - 1) * $XFADE_DUR" | bc -l)
DURACAO_COM_COMPENSACAO=$(echo "$DURACAO_TOTAL + $PERDA_TOTAL" | bc -l)
DURACAO_POR_IMAGEM=$(echo "$DURACAO_COM_COMPENSACAO / $NUM_SEGMENTOS" | bc -l)
echo "Duracao real por cena: ${DURACAO_POR_IMAGEM}s"

for ((i=1; i<=NUM_IMAGENS; i++)); do
  IDX=$(printf "%02d" "$i")
  ffmpeg -y -loop 1 -i "img_${IDX}.jpg" -t "$DURACAO_POR_IMAGEM" \
    -vf "scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,zoompan=z='min(zoom+0.0008,1.3)':d=$(echo "$DURACAO_POR_IMAGEM * 25" | bc | cut -d. -f1):s=1920x1080:fps=25" \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p "seg_${IDX}.mp4" -loglevel error
done

echo "== Montando video em lotes (evita filtro gigante do ffmpeg) =="
BATCH_SIZE=10
NUM_BATCHES=$(( (NUM_SEGMENTOS + BATCH_SIZE - 1) / BATCH_SIZE ))
> concat_batches_list.txt
BATCH_IDX=0
for ((start=1; start<=NUM_SEGMENTOS; start+=BATCH_SIZE)); do
  BATCH_IDX=$((BATCH_IDX + 1))
  end=$((start + BATCH_SIZE - 1))
  if [ "$end" -gt "$NUM_SEGMENTOS" ]; then end=$NUM_SEGMENTOS; fi
  BATCH_COUNT=$((end - start + 1))
  BATCH_OUT=$(printf "batch_%03d.mp4" "$BATCH_IDX")

  if [ "$BATCH_COUNT" -eq 1 ]; then
    IMG_INDEX=$(( ((start - 1) % NUM_IMAGENS) + 1 ))
    IDX=$(printf "%02d" "$IMG_INDEX")
    cp "seg_${IDX}.mp4" "$BATCH_OUT"
  else
    BATCH_INPUTS=""
    for ((n=start; n<=end; n++)); do
      IMG_INDEX=$(( ((n - 1) % NUM_IMAGENS) + 1 ))
      IDX=$(printf "%02d" "$IMG_INDEX")
      BATCH_INPUTS="$BATCH_INPUTS -i seg_${IDX}.mp4"
    done
    BATCH_FILTER=""
    OFFSET=$(echo "$DURACAO_POR_IMAGEM - $XFADE_DUR" | bc -l)
    PREV="[0:v]"
    for ((i=1; i<BATCH_COUNT; i++)); do
      NEXT_LABEL="[v$i]"
      if [ "$i" -eq $((BATCH_COUNT-1)) ]; then NEXT_LABEL="[vbatch]"; fi
      BATCH_FILTER="${BATCH_FILTER}${PREV}[${i}:v]xfade=transition=fade:duration=${XFADE_DUR}:offset=${OFFSET}${NEXT_LABEL}; "
      PREV="[v$i]"
      OFFSET=$(echo "$OFFSET + $DURACAO_POR_IMAGEM - $XFADE_DUR" | bc -l)
    done
    BATCH_FILTER=${BATCH_FILTER%; }
    eval ffmpeg -y $BATCH_INPUTS -filter_complex \"$BATCH_FILTER\" -map \"[vbatch]\" -c:v libx264 -preset veryfast -pix_fmt yuv420p "$BATCH_OUT" -loglevel error
  fi
  echo "file '$(pwd)/$BATCH_OUT'" >> concat_batches_list.txt
  echo "  Lote $BATCH_IDX/$NUM_BATCHES pronto ($BATCH_COUNT cenas)"
done

echo "== Concatenando lotes =="
ffmpeg -y -f concat -safe 0 -i concat_batches_list.txt -c copy video_sem_audio.mp4 -loglevel error

echo "== Juntando video + audio + legenda + marca d'agua =="
ffmpeg -y -i video_sem_audio.mp4 -i narracao_completa.m4a \
  -vf "ass=legendas.ass:fontsdir=/usr/share/fonts,drawtext=fontfile=${FONT}:text='Subscribe':fontsize=44:fontcolor=white:borderw=5:bordercolor=black@0.7:box=1:boxcolor=black@0.4:boxborderw=12:x=w-tw-40:y=40" \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -shortest video_final.mp4 -loglevel error
echo "== Video principal pronto =="
ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 video_final.mp4
ls -la video_final.mp4

echo "== Gerando 2 Shorts verticais cortados do video principal =="
SHORT_DUR=50
INICIO_SHORT_1=$(echo "$DURACAO_TOTAL * 0.15" | bc | cut -d. -f1)
INICIO_SHORT_2=$(echo "$DURACAO_TOTAL * 0.6" | bc | cut -d. -f1)
MAX_INICIO=$(echo "$DURACAO_TOTAL - $SHORT_DUR" | bc)
if (( $(echo "$INICIO_SHORT_2 > $MAX_INICIO" | bc -l) )); then INICIO_SHORT_2=$MAX_INICIO; fi

gerar_short() {
  local INICIO=$1
  local OUT=$2
  ffmpeg -y -ss "$INICIO" -i video_final.mp4 -t "$SHORT_DUR" \
    -filter_complex "[0:v]split=2[bg][fg]; \
      [bg]scale=1080:1920,gblur=sigma=20,crop=1080:1920[bgblur]; \
      [fg]scale=1080:-2[fgscaled]; \
      [bgblur][fgscaled]overlay=(W-w)/2:(H-h)/2[base]; \
      [base]drawtext=fontfile=${FONT}:text='Subscribe for more!':fontsize=48:fontcolor=white:borderw=8:bordercolor=black@0.85:shadowx=3:shadowy=3:shadowcolor=black@0.6:box=1:boxcolor=black@0.35:boxborderw=16:x=(w-text_w)/2:y=140" \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac "$OUT" -loglevel error
}
gerar_short "$INICIO_SHORT_1" "short_1.mp4"
gerar_short "$INICIO_SHORT_2" "short_2.mp4"
echo "== Shorts gerados =="
ls -la short_1.mp4 short_2.mp4

echo "== Gerando thumbnail (1280x720) =="
cat > make_thumbnail.py << 'PYEOF'
import sys, textwrap
from PIL import Image, ImageDraw, ImageFont, ImageFilter

def main():
    titulo, out_path = sys.argv[1], sys.argv[2]
    base = Image.open("img_01.jpg").convert("RGB").resize((1280, 720))
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 70)
    linhas = textwrap.wrap(titulo.upper(), width=20)[:3]
    y = 720 - (len(linhas) * 88) - 60
    for linha in linhas:
        bbox = d.textbbox((0, 0), linha, font=font)
        w = bbox[2] - bbox[0]
        x = (1280 - w) / 2
        d.rectangle([x - 20, y - 8, x + w + 20, y + 80], fill=(230, 30, 38, 220))
        d.text((x, y), linha, font=font, fill=(255, 255, 255, 255))
        y += 88
    combined = Image.alpha_composite(base.convert("RGBA"), overlay)
    combined.convert("RGB").save(out_path, quality=92)

if __name__ == "__main__":
    main()
PYEOF
python3 make_thumbnail.py "$TITULO" thumbnail.jpg
echo "== Thumbnail gerada =="
ls -la thumbnail.jpg video_final.mp4 short_1.mp4 short_2.mp4
