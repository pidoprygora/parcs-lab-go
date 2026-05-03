# PARCS-Go Gauss Solver: Як користуватись

## 1) Що це

Цей проєкт розв'язує системи лінійних рівнянь методом Гауса в Docker Swarm, використовуючи PARCS SDK для Go.

Компоненти:
- `gauss-runner` — координатор обчислень.
- `gauss-worker` — воркер, який виконує елімінацію блоку рядків.
- `scripts/run.sh` — скрипт для build/push/run і перегляду логів.
- `scripts/experiments.sh` — пакетний запуск серії кейсів з JSON.

## 2) Підняття інфраструктури

Повний покроковий гайд винесено в `docs/infrastructure.md`.

Два варіанти:
- **Локально** — Docker Swarm + `docker-proxy` на своїй машині.
- **AWS EC2** — Terraform розгортає інстанцію, управління через SSM.

Для запуску `run.sh` і `experiments.sh` потрібен `LEADER_URL=tcp://docker-proxy:4321`.

## 3) Запуск скриптів

Окремий гайд по запуску скриптів дивись у `docs/scripts.md`:
- як запускати `scripts/run.sh`,
- як запускати `scripts/experiments.sh`,
- параметри, приклади і типові помилки.

## 4) Передумови (локальний варіант)

Потрібно встановити:
- Docker Desktop або Docker Engine
- Увімкнений Docker Swarm
- Overlay network `parcs`

Швидка ініціалізація:

```bash
docker swarm init
docker network create -d overlay parcs
```

## 5) Налаштування доступу до Docker API з контейнерів

PARCS-Go запускає дочірні Docker Services з контейнера `gauss-runner`, тому йому потрібен доступ до Docker API.

Практичний варіант для локального запуску:

```bash
docker service create \
  --name docker-proxy \
  --network parcs \
  --restart-condition any \
  --mount type=bind,src="/Users/$USER/.docker/run/docker.sock",dst=/var/run/docker.sock \
  alpine/socat tcp-listen:4321,fork,reuseaddr unix-connect:/var/run/docker.sock
```

Після цього як `LEADER_URL` використовуй:

```bash
tcp://docker-proxy:4321
```

## 6) Базовий запуск

З кореня проєкту — з явною матрицею:

```bash
LEADER_URL='tcp://docker-proxy:4321' \
SKIP_PUSH=1 \
NUM_WORKERS=2 \
MATRIX='[[2,1,-1,8],[-3,-1,2,-11],[-2,1,2,-3]]' \
SERVICE_NAME='gauss-runner-lab' \
./scripts/run.sh
```

Або з генерованою матрицею (рекомендується для великих розмірів):

```bash
LEADER_URL='tcp://docker-proxy:4321' \
SKIP_PUSH=1 \
NUM_WORKERS=4 \
SIZE=1000 \
SEED=42 \
./scripts/run.sh
```

Очікуваний результат у логах для 3×3:
- `x[0] = 2.00000000`
- `x[1] = 3.00000000`
- `x[2] = -1.00000000`

## 7) Формат вхідних даних

Runner підтримує два варіанти задати матрицю:

**`MATRIX`** — JSON масив розширеної матриці `[A|b]`:
- для системи `n x n`: `n` рядків, у кожному `n + 1` елементів.
- підходить для малих та фіксованих матриць.

```text
[[2,1,-1,8],[-3,-1,2,-11],[-2,1,2,-3]]
```

**`SIZE` + `SEED`** — runner генерує випадкову діагонально домінантну матрицю:
- рекомендується для матриць від ~300×300.
- `SEED` опційний, дефолт `42`.

```bash
SIZE=2000 SEED=42
```

## 8) Основні параметри `run.sh`

Обов'язковий:
- `LEADER_URL` — адреса Docker API для PARCS (`tcp://...:4321`)

Вхідні дані (одне з двох):
- `MATRIX` — JSON розширеної матриці (малі матриці)
- `SIZE` — розмір для генерації (великі матриці); `SEED` — опційно

Необов'язкові:
- `REGISTRY_NAMESPACE` (default: `local`)
- `WORKER_IMAGE_NAME` (default: `gauss-worker`)
- `RUNNER_IMAGE_NAME` (default: `gauss-runner`)
- `IMAGE_TAG` (default: `latest`)
- `NUM_WORKERS` (default: `2`)
- `SERVICE_NAME` (default: `gauss-runner`)
- `SKIP_PUSH=1` — не пушити образи в registry
- `WAIT_TIMEOUT_SEC` (default: `540`) — таймаут очікування завершення
- `LOG_FOLLOW=1` — стрімити логи замість полінгу

## 9) Корисні команди

Перевірити стан Swarm:

```bash
docker info --format '{{.Swarm.LocalNodeState}}'
```

Перегляд логів runner:

```bash
docker service logs -f gauss-runner-lab
```

Прибрати сервіси:

```bash
docker service rm gauss-runner-lab docker-proxy
```

## 10) Типові проблеми

- `WORKER_IMAGE env var is required`  
  Перевір, що запуск іде через `scripts/run.sh` або передано `WORKER_IMAGE`.

- `either MATRIX or SIZE env var is required`  
  Передай або `MATRIX=...`, або `SIZE=...`.

- `MATRIX env var is required` або помилка JSON  
  Перевір синтаксис JSON та лапки у shell.

- `singular or near-singular matrix`  
  Матриця вироджена або близька до виродженої.

- Runner не може стартувати worker-сервіси  
  Перевір `LEADER_URL` і доступність Docker API (div. секцію про `docker-proxy`).
