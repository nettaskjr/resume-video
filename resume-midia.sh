#!/bin/bash

# ---------------------------------------------------------
# Script: Áudio/Vídeo -> Whisper -> LM Studio (resumo + 10 questões)
# Uso: ./processar_aula_lmstudio.sh aula.mp4
#      ./processar_aula_lmstudio.sh aula.mp3
#      ./processar_aula_lmstudio.sh aula.wav
# ---------------------------------------------------------

# Endereço do servidor local do LM Studio (OpenAI compatible)
LM_URL="http://127.0.0.1:1234/v1/chat/completions"
LM_MODEL="local-model"  # nome simbólico; LM Studio normalmente ignora ou aceita qualquer string

if [ -z "$1" ]; then
    echo "Uso: $0 arquivo.(mp4|mkv|mp3|wav|m4a|outros)"
    exit 1
fi

ARQUIVO="$1"

if [ ! -f "$ARQUIVO" ]; then
    echo "Erro: Arquivo '$ARQUIVO' não encontrado."
    exit 1
fi

# Verificação de dependências
for cmd in ffmpeg whisper curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Erro: comando '$cmd' não encontrado no sistema: $cmd"
    echo "Instale-o antes de continuar."
    exit 1
  fi
done

BASE="${ARQUIVO%.*}"
EXT="${ARQUIVO##*.}"
EXT_LOWER="${EXT,,}"   # deixa extensão minúscula (bash 4+)

WAV="${BASE}.wav"
TXT_TRANSCRICAO="${BASE}.txt"
TXT_SAIDA="${BASE}_resumo_questoes.txt"
API_RAW="${BASE}_lmstudio_raw.json"

echo ">> Arquivo de entrada: $ARQUIVO"
echo ">> Extensão detectada: .$EXT_LOWER"
echo ">> Base: $BASE"

# ------------ 1) Extrair / preparar áudio ------------

if [ "$EXT_LOWER" = "wav" ]; then
    echo ">> [1/4] Arquivo já é WAV, usando diretamente: $ARQUIVO"
    WAV="$ARQUIVO"
else
    echo ">> [1/4] Extraindo/convetendo áudio com ffmpeg (mono, 16kHz)..."
    ffmpeg -i "$ARQUIVO" -ac 1 -ar 16000 "$WAV" -y
    if [ $? -ne 0 ]; then
        echo "Erro ao extrair/convertar áudio com ffmpeg."
        exit 1
    fi
    echo ">> Áudio gerado: $WAV"
fi

# ------------ 2) Transcrever com Whisper ------------

echo ">> [2/4] Transcrevendo áudio com Whisper (modelo base, pt)..."
echo "   (na primeira vez ele pode baixar o modelo; pode demorar um pouco)"
whisper "$WAV" --model base --language pt --task transcribe
if [ $? -ne 0 ]; then
    echo "Erro: whisper falhou."
    exit 1
fi

if [ ! -f "$TXT_TRANSCRICAO" ]; then
    echo "Erro: transcrição '$TXT_TRANSCRICAO' não foi gerada."
    exit 1
fi
echo ">> Transcrição gerada: $TXT_TRANSCRICAO"

TRANSCRICAO=$(cat "$TXT_TRANSCRICAO")

# ------------ 3) Montar prompt ------------

echo ">> [3/4] Montando prompt para o modelo local (LM Studio)..."

read -r -d '' PROMPT << EOP
Você é um professor.
Abaixo está a transcrição de um vídeo/aula.

1) Primeiro, faça um RESUMO claro e objetivo do conteúdo em português (máximo de 3 parágrafos).

2) Em seguida, crie AO TODO 10 perguntas para testar o conhecimento do aluno, obedecendo exatamente a esta distribuição:
  - 4 questões de MÚLTIPLA ESCOLHA
  - 3 questões de VERDADEIRO ou FALSO
  - 3 questões de COMPLETAR LACUNAS

3) As 10 questões devem vir MISTURADAS, não agrupe por tipo. Embaralhe a ordem das questões.

4) Formato obrigatório de saída:

RESUMO:
[resumo aqui]

PERGUNTAS:
1) [enunciado da pergunta]
Tipo: [Múltipla escolha | Verdadeiro ou Falso | Completar lacuna]
A) ...        (apenas para múltipla escolha)
B) ...
C) ...
D) ...
Resposta correta: [letra certa ou texto]

2) [próxima pergunta]
Tipo: ...
[...]

Regras específicas por tipo:

- MÚLTIPLA ESCOLHA (4 questões):
  * Sempre 4 alternativas: A, B, C, D.
  * Apenas UMA alternativa correta.
  * Escreva no final: "Resposta correta: X" (onde X é A, B, C ou D).

- VERDADEIRO OU FALSO (3 questões):
  * Não use alternativas A, B, C, D.
  * O enunciado deve poder ser julgado como verdadeiro ou falso.
  * Escreva no final: "Resposta correta: Verdadeiro" ou "Resposta correta: Falso".

- COMPLETAR LACUNAS (3 questões):
  * O enunciado deve conter uma ou mais lacunas sinalizadas por "____".
  * Não use alternativas A, B, C, D.
  * No final, escreva: "Resposta correta: [texto que completa a lacuna]".

Use sempre o conteúdo da transcrição para formular o resumo e todas as perguntas.

TRANSCRIÇÃO DO VÍDEO:
$TRANSCRICAO
EOP


# ------------ 4) Chamada ao LM Studio ------------

echo ">> [4/4] Enviando para o LM Studio em $LM_URL ..."
echo "   Resposta bruta será salva em: $API_RAW"

JSON_PAYLOAD=$(jq -n --arg sys "Você é um assistente especializado em educação." \
                    --arg prompt "$PROMPT" \
                    --arg model "$LM_MODEL" \
    '{
        model: $model,
        messages: [
          {role: "system", content: $sys},
          {role: "user", content: $prompt}
        ]
      }')

RESPOSTA=$(curl -s "$LM_URL" \
  -H "Content-Type: application/json" \
  -d "$JSON_PAYLOAD")

# Salvar resposta bruta (para debug)
echo "$RESPOSTA" > "$API_RAW"

# Tentar detectar erro no formato OpenAI-like
ERROR_MSG=$(echo "$RESPOSTA" | jq -r '.error.message' 2>/dev/null || echo "")

if [ "$ERROR_MSG" != "" ] && [ "$ERROR_MSG" != "null" ]; then
    echo "Erro retornado pelo LM Studio:"
    echo "$ERROR_MSG"
    echo "Veja o arquivo bruto: $API_RAW"
    exit 1
fi

# Extrair conteúdo principal
CONTEUDO=$(echo "$RESPOSTA" | jq -r '.choices[0].message.content' 2>/dev/null || echo "")

if [ -z "$CONTEUDO" ] || [ "$CONTEUDO" = "null" ]; then
    echo "Não foi possível extrair '.choices[0].message.content'."
    echo "Veja o JSON bruto em: $API_RAW"
    exit 1
fi

echo "$CONTEUDO" > "$TXT_SAIDA"

echo ">> PRONTO!"
echo "Arquivos gerados:"
echo "  - Transcrição: $TXT_TRANSCRICAO"
echo "  - Resumo + 10 questões: $TXT_SAIDA"
echo "  - Resposta bruta do LM Studio: $API_RAW"
