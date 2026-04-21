# Як запускати скрипти

Цей документ описує запуск двох основних скриптів:
- `scripts/run.sh` — один запуск solver для однієї матриці.
- `scripts/experiments.sh` — серія запусків з JSON-конфігом експериментів.

Перед запуском підніми інфраструктуру за `docs/infrastructure.md`.

## 1) `scripts/run.sh` — одиночний запуск

### Обов'язково

- `LEADER_URL` (наприклад `tcp://docker-proxy:4321`)

### Основна команда

```bash
LEADER_URL='tcp://docker-proxy:4321' \
SKIP_PUSH=1 \
./scripts/run.sh
```

### Приклад з явними параметрами

```bash
LEADER_URL='tcp://docker-proxy:4321' \
REGISTRY_NAMESPACE=local \
WORKER_IMAGE_NAME=gauss-worker \
RUNNER_IMAGE_NAME=gauss-runner \
IMAGE_TAG=latest \
NUM_WORKERS=2 \
MATRIX='[[2,1,-1,8],[-3,-1,2,-11],[-2,1,2,-3]]' \
SERVICE_NAME='gauss-runner-lab' \
SKIP_PUSH=1 \
./scripts/run.sh
```

### Корисні параметри `run.sh`

- `LOG_FOLLOW=1` — стрімити логи (`docker service logs -f`) і не чекати фінального статусу.
- `WAIT_TIMEOUT_SEC` — таймаут очікування завершення сервісу (default `180`).
- `POLL_INTERVAL_SEC` — інтервал полінгу стану таски (default `2`).

Приклад:

```bash
LEADER_URL='tcp://docker-proxy:4321' \
SERVICE_NAME='gauss-debug' \
LOG_FOLLOW=1 \
SKIP_PUSH=1 \
./scripts/run.sh
```

## 2) `scripts/experiments.sh` — пакетний запуск

### Обов'язково

- `LEADER_URL` (наприклад `tcp://docker-proxy:4321`)

### Запуск з `scripts/experiments.json`

`scripts/experiments.json` використовується за замовчуванням, тому є два еквівалентні варіанти:

```bash
LEADER_URL='tcp://docker-proxy:4321' \
INPUT_JSON=./scripts/experiments.json \
SKIP_PUSH=1 \
./scripts/experiments.sh
```

або коротко (без `INPUT_JSON`):

```bash
LEADER_URL='tcp://docker-proxy:4321' \
SKIP_PUSH=1 \
./scripts/experiments.sh
```

### Швидкий запуск усіх кейсів

```bash
LEADER_URL='tcp://docker-proxy:4321' \
SKIP_PUSH=1 \
./scripts/experiments.sh
```

### Запуск конкретного експерименту

```bash
LEADER_URL='tcp://docker-proxy:4321' \
EXPERIMENT=case4x4 \
SKIP_PUSH=1 \
./scripts/experiments.sh
```

Те саме з явним файлом:

```bash
LEADER_URL='tcp://docker-proxy:4321' \
INPUT_JSON=./scripts/experiments.json \
EXPERIMENT=case4x4 \
SKIP_PUSH=1 \
./scripts/experiments.sh
```

### Запуск з кастомним JSON

```bash
LEADER_URL='tcp://docker-proxy:4321' \
INPUT_JSON=./my-experiments.json \
SKIP_PUSH=1 \
./scripts/experiments.sh
```

### Корисні параметри `experiments.sh`

- `INPUT_JSON` — шлях до JSON з експериментами (default `./scripts/experiments.json`).
- `EXPERIMENT` — ім'я кейсу або `all` (default `all`).
- `NUM_WORKERS` — дефолтна кількість воркерів, якщо в кейсі немає `num_workers`.
- `REGISTRY_NAMESPACE` — namespace для Docker образів (default `local`).
- `SKIP_PUSH=1` — не пушити образи в registry.

## 3) Формат JSON для `experiments.sh`

Підтримуються два формати:
- масив об'єктів експериментів;
- об'єкт з ключем `experiments`.

Кожен експеримент:
- має `name`,
- має `matrix`,
- опційно `num_workers`.

Приклад:

```json
{
  "experiments": [
    {
      "name": "case3x3_base",
      "num_workers": 2,
      "matrix": [[2, 1, -1, 8], [-3, -1, 2, -11], [-2, 1, 2, -3]]
    },
    {
      "name": "case4x4",
      "num_workers": 4,
      "matrix": [[1, 2, 3, 4, 10], [2, 1, 1, 0, 4], [3, 1, 2, 1, 7], [1, 0, 1, 2, 5]]
    }
  ]
}
```

## 4) Типові помилки

- `LEADER_URL is required`  
  Додай `LEADER_URL='tcp://docker-proxy:4321'`.

- `Input JSON file not found`  
  Перевір `INPUT_JSON`.

- `Experiment '<name>' not found`  
  Перевір ім'я кейсу у JSON.

- `singular or near-singular matrix`  
  Матриця вироджена або чисельно нестійка для поточного pivoting.
