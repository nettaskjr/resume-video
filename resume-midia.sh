#!/bin/bash

# ---------------------------------------------------------
# Script: Áudio/Vídeo -> Whisper -> LLM (resumo + 10 questões)
# Uso: ./resume-midia.sh [opções] arquivo.mp4
# ---------------------------------------------------------

## --- Variáveis Globais ---
ARQUIVO=""
PROVIDER="" # Será definido a partir do config.json
CONFIG_FILE="config.json"

mostrar_ajuda() {
  echo "Uso: $0 [opções] <arquivo>"
  echo
  echo "Processa um arquivo de áudio/vídeo para gerar uma transcrição, um resumo e 10 questões de múltipla escolha."
  echo
  echo "Opções:"
  echo "  --provider [serviço]   Define o provedor de LLM a ser usado. Padrão: lmstudio."
  echo "                           Opções disponíveis: lmstudio, chatgpt, gemini."
  echo "  --list-models          Lista os modelos disponíveis para o provedor 'gemini' e sai."
  echo "  -h, --help             Mostra esta mensagem de ajuda."
  echo
  echo "Exemplos:"
  echo "  $0 video.mp4"
  echo "  $0 --provider chatgpt audio.mp3"
  echo "  $0 --provider gemini aula.wav"
  echo "  $0 --list-models"
}

listar_modelos_gemini() {
    echo ">> Listando modelos disponíveis na API do Gemini..."
    if [ -z "$GEMINI_API_KEY" ] || [ "$GEMINI_API_KEY" = "SUA_CHAVE_GEMINI_AQUI" ]; then
        echo "Erro: A chave de API do Gemini não está configurada em '$CONFIG_FILE'." >&2
        exit 1
    fi
    curl -s "https://generativelanguage.googleapis.com/v1beta/models?key=${GEMINI_API_KEY}" | jq .
}

# --- Carregamento de Configurações ---
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Erro: Arquivo de configuração '$CONFIG_FILE' não encontrado." >&2
    echo "Copie 'config.json.example' para '$CONFIG_FILE' e preencha com suas chaves de API." >&2
    exit 1
fi

# Ler configurações do JSON usando jq
PROVIDER=$(jq -r '.default_provider' "$CONFIG_FILE")
LMSTUDIO_URL=$(jq -r '.providers.lmstudio.url' "$CONFIG_FILE")
LMSTUDIO_MODEL=$(jq -r '.providers.lmstudio.model' "$CONFIG_FILE")
OPENAI_URL=$(jq -r '.providers.chatgpt.url' "$CONFIG_FILE")
OPENAI_MODEL=$(jq -r '.providers.chatgpt.model' "$CONFIG_FILE")
OPENAI_API_KEY=$(jq -r '.providers.chatgpt.api_key' "$CONFIG_FILE")
GEMINI_URL=$(jq -r '.providers.gemini.url' "$CONFIG_FILE")
GEMINI_API_KEY=$(jq -r '.providers.gemini.api_key' "$CONFIG_FILE")
GEMINI_MODEL=$(jq -r '.providers.gemini.model' "$CONFIG_FILE")

# Verifica se o provedor padrão foi carregado corretamente
if [ -z "$PROVIDER" ] || [ "$PROVIDER" = "null" ]; then
    echo "Erro: A chave 'default_provider' não está definida ou é nula em '$CONFIG_FILE'." >&2
    # Define um fallback para garantir que o script não quebre
    PROVIDER="lmstudio"
    echo "Usando 'lmstudio' como fallback."
fi

# --- Processamento de Argumentos ---
while [ "$#" -gt 0 ]; do
    case "$1" in
        --provider) PROVIDER="$2"; shift 2 ;;
        --list-models) listar_modelos_gemini; exit 0 ;;
        -h|--help) mostrar_ajuda; exit 0 ;;
        -*) echo "Opção desconhecida: $1"; mostrar_ajuda; exit 1 ;;
        *) ARQUIVO="$1"; shift 1 ;;
    esac
done

if [ -z "$ARQUIVO" ]; then
    echo "Erro: Nenhum arquivo de entrada especificado."
    mostrar_ajuda
    exit 1
fi

if [ ! -f "$ARQUIVO" ]; then
    echo "Erro: Arquivo '$ARQUIVO' não encontrado." >&2
    exit 1
fi

# Verificação de dependências
for cmd in ffmpeg whisper curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Erro: comando '$cmd' não encontrado no sistema: $cmd"
    echo "Instale-o antes de continuar." >&2
    exit 1
  fi
done

# Verificação de chaves de API lidas do JSON
if [ "$PROVIDER" = "chatgpt" ]; then
    if [ -z "$OPENAI_API_KEY" ] || [ "$OPENAI_API_KEY" = "SUA_CHAVE_OPENAI_AQUI" ]; then
        echo "Erro: A chave de API do ChatGPT não está configurada em '$CONFIG_FILE'." >&2
        exit 1
    fi
fi

if [ "$PROVIDER" = "gemini" ]; then
    if [ -z "$GEMINI_API_KEY" ] || [ "$GEMINI_API_KEY" = "SUA_CHAVE_GEMINI_AQUI" ]; then
        echo "Erro: A chave de API do Gemini não está configurada em '$CONFIG_FILE'." >&2
        exit 1
    fi
fi

BASE="${ARQUIVO%.*}"
EXT="${ARQUIVO##*.}"
EXT_LOWER="${EXT,,}"   # deixa extensão minúscula (bash 4+)

WAV="${BASE}.wav"
TXT_TRANSCRICAO="${BASE}.txt"
TXT_SAIDA="${BASE}_resumo_questoes.txt"
API_RAW="${BASE}_${PROVIDER}_raw.json"

echo ">> Arquivo de entrada: $ARQUIVO"
echo ">> Extensão detectada: .$EXT_LOWER"
echo ">> Provedor LLM: $PROVIDER"
echo ">> Base: $BASE"

if [ "$EXT_LOWER" = "txt" ]; then
    echo ">> [1/2] Arquivo de texto detectado. Pulando extração de áudio e transcrição."
    TRANSCRICAO=$(cat "$ARQUIVO")
    if [ -z "$TRANSCRICAO" ]; then
        echo "Erro: O arquivo de texto '$ARQUIVO' está vazio." >&2
        exit 1
    fi
    echo ">> Conteúdo do texto carregado com sucesso."
else
    # ------------ 1) Extrair / preparar áudio ------------
    if [ "$EXT_LOWER" = "wav" ]; then
        echo ">> [1/4] Arquivo já é WAV, usando diretamente: $ARQUIVO"
        WAV="$ARQUIVO"
    else
        echo ">> [1/4] Extraindo/convetendo áudio com ffmpeg (mono, 16kHz)..."
        ffmpeg -i "$ARQUIVO" -ac 1 -ar 16000 "$WAV" -y
        if [ $? -ne 0 ]; then
            echo "Erro ao extrair/converter áudio com ffmpeg." >&2
            exit 1
        fi
        echo ">> Áudio gerado: $WAV"
    fi

    # ------------ 2) Transcrever com Whisper ------------
    echo ">> [2/4] Transcrevendo áudio com Whisper (modelo base, pt)..."
    echo "   (na primeira vez ele pode baixar o modelo; pode demorar um pouco)"
    whisper "$WAV" --model base --language pt --task transcribe
    if [ $? -ne 0 ]; then
        echo "Erro: whisper falhou." >&2
        exit 1
    fi

    if [ ! -f "$TXT_TRANSCRICAO" ]; then
        echo "Erro: transcrição '$TXT_TRANSCRICAO' não foi gerada." >&2
        exit 1
    fi
    echo ">> Transcrição gerada: $TXT_TRANSCRICAO"
    TRANSCRICAO=$(cat "$TXT_TRANSCRICAO")
fi

# ------------ 3) Montar prompt ------------

echo ">> [2/3] Configurando a geração de perguntas..."

read -p "Quantas perguntas você deseja gerar? (padrão: 10): " TOTAL_QUESTOES
TOTAL_QUESTOES=${TOTAL_QUESTOES:-10} # Se vazio, usa 10

# Calcula a quantidade de questões por tipo (40% ME, 30% VF, 30% CL)
# Usamos awk para aritmética de ponto flutuante e printf para arredondar
QTD_ME=$(printf "%.0f" $(awk "BEGIN {print $TOTAL_QUESTOES * 0.4}"))
QTD_VF=$(printf "%.0f" $(awk "BEGIN {print $TOTAL_QUESTOES * 0.3}"))
QTD_CL=$(printf "%.0f" $(awk "BEGIN {print $TOTAL_QUESTOES * 0.3}"))

# Ajusta a soma para garantir que o total seja o solicitado
SOMA_ATUAL=$((QTD_ME + QTD_VF + QTD_CL))
DIFERENCA=$((TOTAL_QUESTOES - SOMA_ATUAL))
QTD_ME=$((QTD_ME + DIFERENCA)) # Adiciona a diferença à categoria principal

echo ">> Montando prompt com $TOTAL_QUESTOES perguntas ($QTD_ME Múltipla Escolha, $QTD_VF Verdadeiro/Falso, $QTD_CL Completar Lacuna)..."

read -r -d '' PROMPT << EOP
Você é um professor.
Abaixo está a transcrição de um vídeo/aula.

1) Primeiro, faça um RESUMO claro e objetivo do conteúdo em português (máximo de 3 parágrafos).

2) Em seguida, crie AO TODO $TOTAL_QUESTOES perguntas para testar o conhecimento do aluno, obedecendo exatamente a esta distribuição:
  - $QTD_ME questões de MÚLTIPLA ESCOLHA
  - $QTD_VF questões de VERDADEIRO ou FALSO
  - $QTD_CL questões de COMPLETAR LACUNAS

3) As $TOTAL_QUESTOES questões devem vir MISTURADAS, não agrupe por tipo. Embaralhe a ordem das questões.

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

- MÚLTIPLA ESCOLHA ($QTD_ME questões):
  * Sempre 4 alternativas: A, B, C, D.
  * Apenas UMA alternativa correta.
  * Escreva no final: "Resposta correta: X" (onde X é A, B, C ou D).

- VERDADEIRO OU FALSO ($QTD_VF questões):
  * Não use alternativas A, B, C, D.
  * O enunciado deve poder ser julgado como verdadeiro ou falso.
  * Escreva no final: "Resposta correta: Verdadeiro" ou "Resposta correta: Falso".

- COMPLETAR LACUNAS ($QTD_CL questões):
  * O enunciado deve conter uma ou mais lacunas sinalizadas por "____".
  * Não use alternativas A, B, C, D.
  * No final, escreva: "Resposta correta: [texto que completa a lacuna]".

Use sempre o conteúdo da transcrição para formular o resumo e todas as perguntas.

TRANSCRIÇÃO DO VÍDEO:
$TRANSCRICAO
EOP


# ------------ 4) Chamada ao LM Studio ------------

echo ">> [3/3] Enviando para o provedor '$PROVIDER' via API..."
echo "   Resposta bruta será salva em: $API_RAW"

RESPOSTA=""

case "$PROVIDER" in
  "lmstudio")
    JSON_PAYLOAD=$(jq -n --arg sys "Você é um assistente especializado em educação." \
                        --arg prompt "$PROMPT" \
                        --arg model "$LMSTUDIO_MODEL" \
        '{model: $model, messages: [{role: "system", content: $sys}, {role: "user", content: $prompt}]}')
    RESPOSTA=$(curl -s "$LMSTUDIO_URL" -H "Content-Type: application/json" -d "$JSON_PAYLOAD")
    ;;

  "chatgpt")
    JSON_PAYLOAD=$(jq -n --arg sys "Você é um assistente especializado em educação." \
                        --arg prompt "$PROMPT" \
                        --arg model "$OPENAI_MODEL" \
        '{model: $model, messages: [{role: "system", content: $sys}, {role: "user", content: $prompt}]}')
    RESPOSTA=$(curl -s "$OPENAI_URL" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -d "$JSON_PAYLOAD")
    ;;

  "gemini")
    JSON_PAYLOAD=$(jq -n --arg prompt "$PROMPT" \
      '{ "contents": [{"parts": [{"text": $prompt}]}] }')
    # Constrói a URL final dinamicamente a partir da base e do modelo
    FINAL_GEMINI_URL="${GEMINI_URL}/${GEMINI_MODEL}:generateContent?key=${GEMINI_API_KEY}"
    RESPOSTA=$(curl -s -X POST "${FINAL_GEMINI_URL}" \
      -H "Content-Type: application/json" \
      -d "$JSON_PAYLOAD")
    ;;

  *)
    echo "Erro: Provedor '$PROVIDER' desconhecido." >&2
    exit 1
    ;;
esac

# Salvar resposta bruta (para debug)
echo "$RESPOSTA" > "$API_RAW"

if [ -z "$RESPOSTA" ]; then
    echo "Erro: A chamada para a API do '$PROVIDER' não retornou nenhuma resposta." >&2
    echo "Verifique se o serviço está em execução (no caso do LM Studio) ou se há conexão com a internet." >&2
    exit 1
fi

# Tentar detectar erro na resposta da API
ERROR_MSG=""
if [ "$PROVIDER" = "gemini" ]; then
    # Gemini pode retornar erro no campo 'error' ou um 'promptFeedback'
    ERROR_MSG=$(echo "$RESPOSTA" | jq -r '.error.message // .promptFeedback.blockReason' 2>/dev/null | grep -v "null")
else
    # Formato OpenAI-like (LM Studio, ChatGPT)
    ERROR_MSG=$(echo "$RESPOSTA" | jq -r '.error.message' 2>/dev/null | grep -v "null")
fi

if [ "$ERROR_MSG" != "" ] && [ "$ERROR_MSG" != "null" ]; then
    echo "Erro retornado pela API do '$PROVIDER':" >&2
    echo "$ERROR_MSG"
    echo "Veja o arquivo bruto para mais detalhes: $API_RAW" >&2
    exit 1
fi

# Extrair conteúdo principal da resposta
CONTEUDO=""
if [ "$PROVIDER" = "gemini" ]; then
    CONTEUDO=$(echo "$RESPOSTA" | jq -r '.candidates[0].content.parts[0].text' 2>/dev/null)
else
    # Formato OpenAI-like
    CONTEUDO=$(echo "$RESPOSTA" | jq -r '.choices[0].message.content' 2>/dev/null)
fi

if [ -z "$CONTEUDO" ] || [ "$CONTEUDO" = "null" ]; then
    echo "Não foi possível extrair o conteúdo da resposta da API." >&2
    echo "Verifique o JSON bruto em: $API_RAW" >&2
    exit 1
fi

echo "$CONTEUDO" > "$TXT_SAIDA"

echo ">> PRONTO!"
echo "Arquivos gerados:"
if [ "$EXT_LOWER" != "txt" ]; then
    echo "  - Transcrição: $TXT_TRANSCRICAO"
fi
echo "  - Resumo + Questões: $TXT_SAIDA"
echo "  - Resposta bruta da API: $API_RAW"
