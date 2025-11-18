# Resumo de Mídia com IA

Este script em Shell (`resume-midia.sh`) automatiza o processo de transcrever um arquivo de áudio ou vídeo, enviar a transcrição para um modelo de linguagem grande (LLM) e gerar um resumo acompanhado de um conjunto de perguntas para avaliação.

## Funcionalidades

-   **Extração de Áudio**: Converte automaticamente arquivos de vídeo (mp4, mkv, etc.) ou áudio para o formato WAV, compatível com o Whisper.
-   **Transcrição Automática**: Utiliza o Whisper para gerar uma transcrição precisa do conteúdo.
-   **Suporte a Múltiplos LLMs**: Integra-se com diferentes provedores de IA:
    -   **LM Studio** (para modelos locais)
    -   **ChatGPT** (via API da OpenAI)
    -   **Gemini** (via API do Google)
-   **Geração de Conteúdo Educacional**:
    -   Cria um resumo conciso do material.
    -   Gera um número personalizável de perguntas de múltipla escolha, verdadeiro/falso e de completar lacunas.
-   **Configuração Flexível**: Todas as chaves de API e endpoints são gerenciados através de um arquivo `config.json`, mantendo a lógica separada das credenciais.

---

## 1. Pré-requisitos

Antes de começar, certifique-se de que as seguintes ferramentas estejam instaladas no seu sistema.

-   **ffmpeg**: Para extração e conversão de áudio.
    ```bash
    # Exemplo no Ubuntu/Debian
    sudo apt update && sudo apt install ffmpeg
    ```
-   **Whisper**: Para a transcrição de áudio. Siga as instruções oficiais de instalação.
    ```bash
    # Exemplo com pip
    pip install -U openai-whisper
    ```
-   **curl**: Para realizar as chamadas de API. Geralmente já vem instalado na maioria dos sistemas Linux.
-   **jq**: Para processar dados em formato JSON.
    ```bash
    # Exemplo no Ubuntu/Debian
    sudo apt install jq
    ```

## 2. Configuração

Siga estes passos para configurar o ambiente.

### Passo 1: Criar o arquivo de configuração

Copie o arquivo de exemplo para criar seu próprio arquivo de configuração:

```bash
cp config.json.example config.json
```

### Passo 2: Configurar os Provedores de IA

Abra o arquivo `config.json` e adicione suas chaves de API e/ou ajuste os endereços.

#### Para LM Studio (Modelos Locais)

1.  Inicie o servidor local do LM Studio.
2.  No arquivo `config.json`, verifique se o `url` corresponde ao endereço do seu servidor (o padrão `http://127.0.0.1:1234/v1/chat/completions` geralmente funciona).

#### Para ChatGPT (OpenAI)

1.  Obtenha sua chave de API no painel da OpenAI: [https://platform.openai.com/api-keys](https://platform.openai.com/api-keys)
2.  No arquivo `config.json`, cole sua chave no campo `api_key` dentro do objeto `chatgpt`.

    ```json
    "chatgpt": {
      "url": "https://api.openai.com/v1/chat/completions",
      "model": "gpt-4o",
      "api_key": "sk-SUA_CHAVE_AQUI"
    }
    ```

#### Para Gemini (Google)

1.  Obtenha sua chave de API no Google AI Studio: [https://aistudio.google.com/app/apikey](https://aistudio.google.com/app/apikey)
2.  No arquivo `config.json`, cole sua chave no campo `api_key` dentro do objeto `gemini`.

    ```json
    "gemini": {
      "url": "https://generativelanguage.googleapis.com/v1beta/models",
      "model": "gemini-1.5-flash-latest",
      "api_key": "AIzaSy...SUA_CHAVE_AQUI"
    }
    ```

### Passo 3: Definir o Provedor Padrão

No `config.json`, você pode definir qual provedor será usado por padrão alterando a chave `default_provider`. As opções são `"lmstudio"`, `"chatgpt"` ou `"gemini"`.

```json
"default_provider": "chatgpt"
```

## 3. Como Usar

Com tudo configurado, execute o script passando o caminho do arquivo de mídia como argumento.

```bash
# Dê permissão de execução ao script (apenas na primeira vez)
chmod +x resume-midia.sh

# Execute o script
./resume-midia.sh /caminho/para/sua/aula.mp4
```

O script irá:
1.  Processar o áudio e gerar a transcrição.
2.  Solicitar interativamente a quantidade de perguntas que você deseja gerar.
3.  Enviar os dados para o provedor de IA configurado e salvar o resultado.

### Usando um Provedor Específico

Você pode sobrescrever o provedor padrão usando a flag `--provider`:

```bash
# Usar o Gemini, mesmo que o padrão seja outro
./resume-midia.sh --provider gemini video.mkv

# Usar o LM Studio
./resume-midia.sh --provider lmstudio audio.mp3
```

## 4. Arquivos de Saída

Para um arquivo de entrada chamado `aula.mp4`, os seguintes arquivos serão gerados no mesmo diretório:

-   `aula.wav`: O áudio extraído e convertido.
-   `aula.txt`: A transcrição bruta gerada pelo Whisper.
-   `aula_resumo_questoes.txt`: O resultado final com o resumo e as perguntas formatadas.
-   `aula_[provider]_raw.json`: A resposta completa da API, útil para depuração.