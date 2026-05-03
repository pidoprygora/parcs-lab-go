# Як запускати скрипти

Цей документ описує запуск двох основних скриптів:
- `scripts/run.sh` — один запуск solver для однієї матриці.
- `scripts/experiments.sh` — серія запусків з JSON-конфігом експериментів.

Перед запуском підніми інфраструктуру за `docs/infrastructure.md`.

## 1) `scripts/run.sh` — одиночний запуск

### Обов'язково

- `LEADER_URL` (наприклад `tcp://docker-proxy:4321`)

### Вхідні дані — два варіанти

**Варіант A: явна матриця через `MATRIX`**

Передається JSON-рядок розширеної матриці `[A|b]`.
Підходить для малих і фіксованих матриць.

```bash
LEADER_URL='tcp://docker-proxy:4321' \
MATRIX='[[2,1,-1,8],[-3,-1,2,-11],[-2,1,2,-3]]' \
SKIP_PUSH=1 \
./scripts/run.sh
```

**Варіант B: розмір через `SIZE` (та опційно `SEED`)**

Runner генерує випадкову діагонально домінантну матрицю розміром `n×n`.
Рекомендується для матриць від ~300×300 — `MATRIX` як env var може перевищити ліміт оболонки.

```bash
LEADER_URL='tcp://docker-proxy:4321' \
SIZE=1000 \
SEED=42 \
SKIP_PUSH=1 \
./scripts/run.sh
```

Якщо жодне з `MATRIX` / `SIZE` не передано, `run.sh` використовує тестовий 3×3 приклад.

### Основна команда (мінімальна)

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
NUM_WORKERS=4 \
SIZE=500 \
SEED=42 \
SERVICE_NAME='gauss-runner-lab' \
SKIP_PUSH=1 \
./scripts/run.sh
```

### Всі параметри `run.sh`

| Змінна               | Дефолт             | Опис                                                          |
|----------------------|--------------------|---------------------------------------------------------------|
| `LEADER_URL`         | **обов'язково**    | Адреса Docker API для PARCS (`tcp://...:4321`)                |
| `MATRIX`             | тестовий 3x3       | JSON розширеної матриці `[A\|b]` (для малих матриць)          |
| `SIZE`               | —                  | Розмір матриці `n` (генерується випадкова діаг. домінантна)   |
| `SEED`               | `42`               | RNG-seed для генерації матриці (тільки при `SIZE`)            |
| `NUM_WORKERS`        | `2`                | Кількість worker-сервісів                                     |
| `SERVICE_NAME`       | `gauss-runner`     | Ім'я Docker-сервісу runner-а                                  |
| `REGISTRY_NAMESPACE` | `local`            | Docker registry namespace                                     |
| `WORKER_IMAGE_NAME`  | `gauss-worker`     | Ім'я Docker-образу worker-а                                   |
| `RUNNER_IMAGE_NAME`  | `gauss-runner`     | Ім'я Docker-образу runner-а                                   |
| `IMAGE_TAG`          | `latest`           | Тег Docker-образів                                            |
| `SKIP_PUSH`          | `0`                | `1` — не пушити образи в registry (рекомендується локально)  |
| `LOG_FOLLOW`         | `0`                | `1` — стрімити логи (`docker service logs -f`)               |
| `WAIT_TIMEOUT_SEC`   | `540`              | Таймаут очікування завершення сервісу (секунди)               |
| `POLL_INTERVAL_SEC`  | `2`                | Інтервал полінгу стану таски (секунди)                        |

### Приклад з `LOG_FOLLOW`

```bash
LEADER_URL='tcp://docker-proxy:4321' \
SERVICE_NAME='gauss-debug' \
LOG_FOLLOW=1 \
SKIP_PUSH=1 \
./scripts/run.sh
```

---

## 2) `scripts/experiments.sh` — пакетний запуск

### Обов'язково

- `LEADER_URL` (наприклад `tcp://docker-proxy:4321`)

### Запуск усіх кейсів

`scripts/experiments.json` використовується за замовчуванням:

```bash
LEADER_URL='tcp://docker-proxy:4321' \
SKIP_PUSH=1 \
./scripts/experiments.sh
```

### Запуск конкретного кейсу

```bash
LEADER_URL='tcp://docker-proxy:4321' \
EXPERIMENT=case1000_w4 \
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

### Параметри `experiments.sh`

| Змінна               | Дефолт                        | Опис                                                          |
|----------------------|-------------------------------|---------------------------------------------------------------|
| `LEADER_URL`         | **обов'язково**               | Адреса Docker API для PARCS                                   |
| `INPUT_JSON`         | `./scripts/experiments.json`  | Шлях до JSON з експериментами                                 |
| `EXPERIMENT`         | `all`                         | Ім'я кейсу або `all`                                          |
| `NUM_WORKERS`        | `2`                           | Глобальний дефолт workers, якщо кейс не визначає `num_workers`|
| `REGISTRY_NAMESPACE` | `local`                       | Docker registry namespace                                     |
| `SKIP_PUSH`          | `1`                           | `1` — не пушити образи                                        |

---

## 3) Формат JSON для `experiments.sh`

Підтримуються два формати:
- масив об'єктів експериментів,
- об'єкт з ключем `experiments`.

Кожен експеримент повинен мати:
- `name` — унікальне ім'я кейсу,
- `matrix` **або** `size` (одне з двох, обов'язково),
- `num_workers` — опційно (якщо не задано, береться глобальний `NUM_WORKERS`).

**Формат з явною матрицею:**

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

**Формат з генерацією за розміром:**

```json
{
  "experiments": [
    { "name": "case1000_w4", "num_workers": 4, "size": 1000, "seed": 42 },
    { "name": "case2000_w4", "num_workers": 4, "size": 2000, "seed": 42 }
  ]
}
```

> При `size`-форматі runner генерує випадкову діагонально домінантну матрицю `n×n`.  
> `seed` — опційно, дефолт `42`.

---

## 4) Типові помилки

- `LEADER_URL is required`  
  Додай `LEADER_URL='tcp://docker-proxy:4321'`.

- `Input JSON file not found`  
  Перевір `INPUT_JSON`.

- `Experiment '<name>' not found`  
  Перевір ім'я кейсу у JSON (список доступних — у `docs/experiments.md`).

- `singular or near-singular matrix`  
  Матриця вироджена або чисельно нестійка для поточного pivoting.

- `WORKER_IMAGE env var is required`  
  Переконайся, що запуск іде через `scripts/run.sh` або передано `WORKER_IMAGE`.

- `either MATRIX or SIZE env var is required`  
  Передай або `MATRIX=...`, або `SIZE=...`.
