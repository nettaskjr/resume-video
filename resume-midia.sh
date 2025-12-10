#!/bin/bash

# ---------------------------------------------------------
# Script: Mídia/Texto -> Whisper -> LLM (resumo + questões)
# Uso: ./resume-midia.sh [opções] arquivo.mp4
# ---------------------------------------------------------

## --- Variáveis Globais ---
# Argumentos e Configuração
CONFIG_FILE="config.json"

# --- Funções ---
mostrar_ajuda() {
    echo "Uso: $0 [opções] <arquivo>"
    echo
    echo "Processa um arquivo de mídia ou texto para gerar um resumo e um questionário."
    echo
    echo "Opções:"
    echo "  --provider [serviço]   Define o provedor de LLM a ser usado. Esta opção também pode ser definida no arquivo de configuração."
    echo "                           Opções disponíveis: lmstudio, chatgpt, gemini."
    echo "  --list-models [provedor] Lista os modelos disponíveis para o provedor (chatgpt ou gemini)."
    echo "  -h, --help             Mostra esta mensagem de ajuda."
    echo
    echo "Exemplos:"
    echo "  $0 video.mp4"
    echo "  $0 --provider chatgpt audio.mp3"
    echo "  $0 --list-models chatgpt"
}

listar_modelos_chatgpt() {
    echo ">> Listando modelos disponíveis na API da OpenAI (ChatGPT)..."
    if [ -z "$OPENAI_API_KEY" ] || [ "$OPENAI_API_KEY" = "SUA_CHAVE_OPENAI_AQUI" ]; then
        echo "Erro: A chave de API do ChatGPT não está configurada em '$CONFIG_FILE'." >&2
        exit 1
    fi
    # Filtra para mostrar apenas os modelos 'gpt' e seus IDs
    # Captura o corpo e o código de status HTTP separadamente
    RESPONSE=$(curl -s -w "\n%{http_code}" "https://api.openai.com/v1/models" \
        -H "Authorization: Bearer $OPENAI_API_KEY")
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    # Verifica o código de status HTTP
    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "Erro: A API da OpenAI retornou um código de status HTTP $HTTP_CODE." >&2
        if [ "$HTTP_CODE" -eq 401 ]; then
            echo "Causa provável: Chave de API inválida ou expirada." >&2
        elif [ "$HTTP_CODE" -ge 500 ]; then
            echo "Causa provável: Erro temporário no servidor da OpenAI. Por favor, tente novamente mais tarde." >&2
        fi
        echo "Resposta da API: $BODY" >&2
        exit 1
    fi

    # Processa a resposta JSON
    echo "$BODY" | jq '.data[] | select(.id | startswith("gpt")) | {id, created, owned_by}'
}

listar_modelos_gemini() {
    echo ">> Listando modelos disponíveis na API do Gemini..."
    if [ -z "$GEMINI_API_KEY" ] || [ "$GEMINI_API_KEY" = "SUA_CHAVE_GEMINI_AQUI" ]; then
        echo "Erro: A chave de API do Gemini não está configurada em '$CONFIG_FILE'." >&2
        exit 1
    fi
    curl -s "https://generativelanguage.googleapis.com/v1beta/models?key=${GEMINI_API_KEY}" | jq .
}

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Erro: Arquivo de configuração '$CONFIG_FILE' não encontrado." >&2
        echo "Copie 'config.json.example' para '$CONFIG_FILE' e preencha com suas chaves de API." >&2
        exit 1
    fi

    PROVIDER=$(jq -r '.default_provider' "$CONFIG_FILE")
    WHISPER_MODEL=$(jq -r '.whisper_model' "$CONFIG_FILE")
    LMSTUDIO_URL=$(jq -r '.providers.lmstudio.url' "$CONFIG_FILE")
    LMSTUDIO_MODEL=$(jq -r '.providers.lmstudio.model' "$CONFIG_FILE")
    OPENAI_URL=$(jq -r '.providers.chatgpt.url' "$CONFIG_FILE")
    OPENAI_MODEL=$(jq -r '.providers.chatgpt.model' "$CONFIG_FILE")
    OPENAI_API_KEY=$(jq -r '.providers.chatgpt.api_key' "$CONFIG_FILE")
    GEMINI_URL=$(jq -r '.providers.gemini.url' "$CONFIG_FILE")
    GEMINI_API_KEY=$(jq -r '.providers.gemini.api_key' "$CONFIG_FILE")
    GEMINI_MODEL=$(jq -r '.providers.gemini.model' "$CONFIG_FILE")

    if [ -z "$PROVIDER" ] || [ "$PROVIDER" = "null" ]; then
        echo "Aviso: 'default_provider' não definido. Usando 'gemini' como fallback." >&2
        PROVIDER="gemini"
    fi
    if [ -z "$WHISPER_MODEL" ] || [ "$WHISPER_MODEL" = "null" ]; then
        echo "Aviso: 'whisper_model' não definido. Usando 'base' como padrão." >&2
        WHISPER_MODEL="base"
    fi
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --provider) PROVIDER="$2"; shift 2 ;;
            --list-models)
                local list_provider="$2"
                case "$list_provider" in
                    "chatgpt") listar_modelos_chatgpt; exit 0 ;;
                    "gemini") listar_modelos_gemini; exit 0 ;;
                    *)
                        echo "Erro: Especifique um provedor para listar os modelos ('chatgpt' ou 'gemini')." >&2
                        echo "Exemplo: $0 --list-models chatgpt" >&2
                        exit 1
                        ;;
                esac
                ;;
            -h|--help) mostrar_ajuda; exit 0 ;;
            -*) echo "Opção desconhecida: $1"; mostrar_ajuda; exit 1 ;;
            *) ARQUIVO="$1"; shift 1 ;;
        esac
    done
}

check_dependencies() {
    for cmd in ffmpeg whisper curl jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Erro: comando '$cmd' não encontrado no sistema: $cmd" >&2
            echo "Instale-o antes de continuar." >&2
            exit 1
        fi
    done
}

check_api_keys() {
    if [ "$PROVIDER" = "chatgpt" ] && ([ -z "$OPENAI_API_KEY" ] || [ "$OPENAI_API_KEY" = "SUA_CHAVE_OPENAI_AQUI" ]); then
        echo "Erro: A chave de API do ChatGPT não está configurada em '$CONFIG_FILE'." >&2
        exit 1
    fi
    if [ "$PROVIDER" = "gemini" ] && ([ -z "$GEMINI_API_KEY" ] || [ "$GEMINI_API_KEY" = "SUA_CHAVE_GEMINI_AQUI" ]); then
        echo "Erro: A chave de API do Gemini não está configurada em '$CONFIG_FILE'." >&2
        exit 1
    fi
}

process_input_file() {
    local ext_lower
    ext_lower=$(echo "${ARQUIVO##*.}" | tr '[:upper:]' '[:lower:]')

    if [ "$ext_lower" = "txt" ]; then
        echo ">> Arquivo de texto detectado. Pulando extração e transcrição." >&2
        local content
        content=$(cat "$ARQUIVO")
        if [ -z "$content" ]; then
            echo "Erro: O arquivo de texto '$ARQUIVO' está vazio." >&2
            exit 1
        fi
        echo ">> Conteúdo do texto carregado com sucesso." >&2
        echo "$content"
        return
    fi

    # Processamento de mídia
    if [ "$ext_lower" = "wav" ]; then
        echo ">> Arquivo já é WAV, usando diretamente: $ARQUIVO" >&2
        WAV="$ARQUIVO"
    else
        echo ">> Extraindo/convertendo áudio com ffmpeg (mono, 16kHz)..." >&2
        ffmpeg -i "$ARQUIVO" -ac 1 -ar 16000 "$WAV" -y >/dev/null 2>&1
        if [ $? -ne 0 ]; then echo "Erro ao extrair/converter áudio com ffmpeg." >&2; exit 1; fi
        echo ">> Áudio gerado: $WAV" >&2
    fi

    echo ">> Transcrevendo áudio com Whisper (modelo: $WHISPER_MODEL, idioma: pt)..." >&2
    # Executa o whisper
    # Usamos --verbose False para que a transcrição seja enviada para stdout em tempo real
    # e 'tee' para exibir na tela e salvar no arquivo simultaneamente.
    whisper "$WAV" --model "$WHISPER_MODEL" --verbose False --language pt | tee "$TXT_TRANSCRICAO"
    if [ $? -ne 0 ]; then echo "Erro: whisper falhou." >&2; exit 1; fi

    if [ ! -f "$TXT_TRANSCRICAO" ]; then
        echo "Erro: transcrição '$TXT_TRANSCRICAO' não foi gerada." >&2
        exit 1
    fi
    echo ">> Transcrição gerada: $TXT_TRANSCRICAO" >&2
    cat "$TXT_TRANSCRICAO"
}

build_llm_prompt() {
    local transcricao="$1"
    local total_paragrafos total_questoes
    local qtd_me qtd_vf qtd_cl soma_atual diferenca

    echo ">> Configurando a geração de resumo e perguntas..." >&2
    read -p "Quantos parágrafos para o resumo? (padrão: 3): " total_paragrafos
    total_paragrafos=${total_paragrafos:-3}

    while true; do
        read -p "Quantas perguntas você deseja gerar? (mínimo: 10, padrão: 10): " total_questoes
        total_questoes=${total_questoes:-10}
        if [ "$total_questoes" -ge 10 ]; then
            break
        else
            echo "Erro: O número de perguntas deve ser 10 ou mais. Tente novamente." >&2
        fi
    done
    
    # 40% múltipla escolha, 30% verdadeiro/falso, 30% completar lacunas
    qtd_me=$(awk "BEGIN {print int(($total_questoes * 0.4) + 0.9)}")
    qtd_vf=$(awk "BEGIN {print int(($total_questoes * 0.3) + 0.9)}")
    qtd_cl=$(awk "BEGIN {print int(($total_questoes * 0.3) + 0.9)}")

    soma_atual=$((qtd_me + qtd_vf + qtd_cl))
    diferenca=$((total_questoes - soma_atual))
    qtd_me=$((qtd_me + diferenca))

    echo ">> Montando prompt para um resumo de $total_paragrafos parágrafos e $total_questoes perguntas." >&2

    read -r -d '' PROMPT_TEMPLATE << EOP
Você é um professor.
Abaixo está a transcrição de um vídeo/aula.

1) Primeiro, faça um RESUMO claro e objetivo do conteúdo em português (máximo de ${total_paragrafos} parágrafos).

2) Em seguida, crie AO TODO ${total_questoes} perguntas para testar o conhecimento do aluno, obedecendo exatamente a esta distribuição:
    - ${qtd_me} questões de MÚLTIPLA ESCOLHA
    - ${qtd_vf} questões de VERDADEIRO ou FALSO
    - ${qtd_cl} questões de COMPLETAR LACUNAS

3) As ${total_questoes} questões devem vir MISTURADAS, não agrupe por tipo. Embaralhe a ordem das questões.

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

2) [próxima pergunta]
Tipo: ...
[...]

GABARITO:
1) Resposta correta: [letra certa ou texto]
    Justificativa: [explicação do porquê a resposta está correta, baseada na transcrição]
2) Resposta correta: ...
    Justificativa: ...

Regras específicas por tipo:

- MÚLTIPLA ESCOLHA (${qtd_me} questões):
  * Sempre 4 alternativas: A, B, C, D.
  * Apenas UMA alternativa correta.

- VERDADEIRO OU FALSO (${qtd_vf} questões):
  * Não use alternativas A, B, C, D.
  * O enunciado deve poder ser julgado como verdadeiro ou falso.

- COMPLETAR LACUNAS (${qtd_cl} questões):
  * O enunciado deve conter uma ou mais lacunas sinalizadas por "____".
  * Não use alternativas A, B, C, D.

Use sempre o conteúdo da transcrição para formular o resumo e todas as perguntas.

TRANSCRIÇÃO DO VÍDEO:
${transcricao}
EOP
    echo "$PROMPT_TEMPLATE"
}

call_llm_api() {
    local prompt="$1"
    local json_payload resposta

    echo ">> Enviando para o provedor '$PROVIDER' via API..." >&2
    echo "   Resposta bruta será salva em: $API_RAW"

    case "$PROVIDER" in
        "lmstudio")
            json_payload=$(jq -n --arg sys "Você é um assistente especializado em educação." \
                                --arg prompt "$prompt" --arg model "$LMSTUDIO_MODEL" \
                '{model: $model, messages: [{role: "system", content: $sys}, {role: "user", content: $prompt}]}')
            resposta=$(curl -s "$LMSTUDIO_URL" -H "Content-Type: application/json" -d "$json_payload")
            ;;
        "chatgpt")
            json_payload=$(jq -n --arg sys "Você é um assistente especializado em educação." \
                                --arg prompt "$prompt" --arg model "$OPENAI_MODEL" \
                '{model: $model, messages: [{role: "system", content: $sys}, {role: "user", content: $prompt}]}')
            resposta=$(curl -s "$OPENAI_URL" -H "Content-Type: application/json" \
                -H "Authorization: Bearer $OPENAI_API_KEY" -d "$json_payload")
            ;;
        "gemini")
            json_payload=$(jq -n --arg prompt "$prompt" \
                '{ "contents": [{"parts": [{"text": $prompt}]}] }')
            local final_gemini_url="${GEMINI_URL}/${GEMINI_MODEL}:generateContent?key=${GEMINI_API_KEY}"
            resposta=$(curl -s -X POST "${final_gemini_url}" \
                -H "Content-Type: application/json" -d "$json_payload")
            ;;
        *)
            echo "Erro: Provedor '$PROVIDER' desconhecido." >&2; exit 1 ;;
    esac

    echo "$resposta" > "$API_RAW"
}

extract_content_from_response() {
    local raw_response="$1"
    local error_msg content

    if [ -z "$raw_response" ]; then
        echo "Erro: A chamada para a API do '$PROVIDER' não retornou nenhuma resposta." >&2
        echo "Verifique se o serviço está em execução (no caso do LM Studio) ou se há conexão com a internet." >&2
        exit 1
    fi

    if [ "$PROVIDER" = "gemini" ]; then
        error_msg=$(echo "$raw_response" | jq -r '.error.message // .promptFeedback.blockReason' 2>/dev/null | grep -v "null")
    else
        error_msg=$(echo "$raw_response" | jq -r '.error.message' 2>/dev/null | grep -v "null")
    fi

    if [ -n "$error_msg" ] && [ "$error_msg" != "null" ]; then
        echo "Erro retornado pela API do '$PROVIDER':" >&2
        echo "$error_msg"
        echo "Veja o arquivo bruto para mais detalhes: $API_RAW" >&2
        exit 1
    fi

    if [ "$PROVIDER" = "gemini" ]; then
        content=$(echo "$raw_response" | jq -r '.candidates[0].content.parts[0].text' 2>/dev/null)
    else
        content=$(echo "$raw_response" | jq -r '.choices[0].message.content' 2>/dev/null)
    fi

    if [ -z "$content" ] || [ "$content" = "null" ]; then
        echo "Não foi possível extrair o conteúdo da resposta da API." >&2
        echo "Verifique o JSON bruto em: $API_RAW" >&2
        exit 1
    fi

    echo "$content"
}

check_files() {
    if [ -z "$ARQUIVO" ]; then
        echo "Erro: Nenhum arquivo de entrada especificado." >&2
        mostrar_ajuda
        exit 1
    fi

    if [ ! -f "$ARQUIVO" ]; then
        echo "Erro: Arquivo '$ARQUIVO' não encontrado." >&2
        exit 1
    fi
}

main() {
    load_config
    parse_args "$@"

    check_files

    check_dependencies
    check_api_keys

    BASE="${ARQUIVO%.*}"
    WAV="${BASE}.wav"
    TXT_TRANSCRICAO="${BASE}.txt"
    TXT_SAIDA="${BASE}_resumo_questoes.txt"
    API_RAW="${BASE}_${PROVIDER}_raw.json"

    echo ">> Arquivo de entrada: $ARQUIVO"
    echo ">> Provedor LLM: $PROVIDER"
    echo ">> Modelo Whisper: $WHISPER_MODEL"

    local transcricao
    transcricao=$(process_input_file)
    
    local prompt
    prompt=$(build_llm_prompt "$transcricao")

    # Chama a API, que salva a resposta no arquivo API_RAW
    call_llm_api "$prompt"

    # Lê o conteúdo do arquivo bruto e extrai a resposta final
    local final_content=$(extract_content_from_response "$(cat "$API_RAW")")

    echo "$final_content" > "$TXT_SAIDA"

    echo ">> PRONTO!"
    echo "Arquivos gerados:"
    local ext_lower
    ext_lower=$(echo "${ARQUIVO##*.}" | tr '[:upper:]' '[:lower:]')
    if [ "$ext_lower" != "txt" ]; then
        echo "  - Transcrição: $TXT_TRANSCRICAO"
    fi
    echo "  - Resumo + Questões: $TXT_SAIDA"
    echo "  - Resposta bruta da API: $API_RAW"
}

# --- Ponto de Entrada ---
main "$@"
