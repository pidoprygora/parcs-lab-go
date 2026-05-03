# Набір експериментів

Цей документ містить готові сценарії, які читаються з `scripts/experiments.json`.

## Швидкий старт

1. Підніми інфраструктуру за інструкцією з `docs/infrastructure.md`.
2. Запусти:

```bash
LEADER_URL=tcp://docker-proxy:4321 SKIP_PUSH=1 ./scripts/experiments.sh
```

Це виконає всі експерименти з `scripts/experiments.json` по черзі.
Наприкінці скрипт виведе підсумкову таблицю з:
- назвою експерименту,
- кількістю воркерів,
- типом входу (`matrix` / розміром),
- часом виконання алгоритму (`ALGO_DURATION_MS`),
- статусом,
- скороченим вектором розв'язку (`SOLUTION_JSON`).

## Запуск конкретного кейсу

```bash
LEADER_URL=tcp://docker-proxy:4321 \
EXPERIMENT=case4x4 \
SKIP_PUSH=1 \
./scripts/experiments.sh
```

`NUM_WORKERS` у цьому режимі — глобальний дефолт.
Якщо у JSON для конкретного кейсу задано `num_workers`, він має пріоритет.

---

## Перелік усіх кейсів у `experiments.json`

### Малі фіксовані матриці

| Ім'я                    | Розмір | Workers | Опис                                          |
|-------------------------|--------|---------|-----------------------------------------------|
| `case3x3_base`          | 3×3    | 2       | Базова перевірка коректності (`x=[2,3,-1]`)   |
| `case3x3_diag_dominant` | 3×3    | 2       | Стабільна діагонально домінантна система      |
| `case4x4`               | 4×4    | 4       | Перевірка розбиття рядків по workers          |
| `case5x5_sparse`        | 5×5    | 5       | Розріджена система, near-zero обнулення       |

### Порівняння workers (фіксована матриця 8×8)

| Ім'я         | Workers |
|--------------|---------|
| `case8x8_w1` | 1       |
| `case8x8_w2` | 2       |
| `case8x8_w4` | 4       |

### Порівняння workers (фіксована матриця 10×10)

| Ім'я           | Workers |
|----------------|---------|
| `case10x10_w1` | 1       |
| `case10x10_w2` | 2       |
| `case10x10_w4` | 4       |
| `case10x10_w8` | 8       |

### Масштабування — генеровані матриці (SIZE + SEED)

Всі кейси нижче генерують випадкову діагонально домінантну матрицю (`seed=42`).

| Ім'я           | Розмір  | Workers |
|----------------|---------|---------|
| `case100_w1`   | 100×100 | 1       |
| `case100_w2`   | 100×100 | 2       |
| `case100_w4`   | 100×100 | 4       |
| `case500_w1`   | 500×500 | 1       |
| `case500_w2`   | 500×500 | 2       |
| `case500_w4`   | 500×500 | 4       |
| `case1000_w1`  | 1000×1000 | 1     |
| `case1000_w2`  | 1000×1000 | 2     |
| `case1000_w4`  | 1000×1000 | 4     |
| `case2000_w1`  | 2000×2000 | 1     |
| `case2000_w2`  | 2000×2000 | 2     |
| `case2000_w4`  | 2000×2000 | 4     |

---

## Варіанти типових сценаріїв

### 1) Базовий контрольний (3×3)

```bash
LEADER_URL=tcp://docker-proxy:4321 \
EXPERIMENT=case3x3_base \
SKIP_PUSH=1 \
./scripts/experiments.sh
```

Очікувано: `x=[2, 3, -1]`.

### 2) Перевірка розбиття по workers (4×4)

```bash
LEADER_URL=tcp://docker-proxy:4321 \
EXPERIMENT=case4x4 \
SKIP_PUSH=1 \
./scripts/experiments.sh
```

Рекомендація: прогнати також з `NUM_WORKERS=1` і `NUM_WORKERS=2` і порівняти `ALGO_DURATION_MS`.

### 3) Серія масштабування (фіксована матриця)

```bash
for w in 1 2 4 8; do
  echo "=== NUM_WORKERS=$w ==="
  LEADER_URL=tcp://docker-proxy:4321 \
  EXPERIMENT=case10x10_w${w} \
  SKIP_PUSH=1 \
  ./scripts/experiments.sh
done
```

### 4) Серія масштабування (великі розміри)

```bash
for name in case100_w1 case100_w2 case100_w4 \
            case500_w1 case500_w2 case500_w4 \
            case1000_w1 case1000_w2 case1000_w4; do
  LEADER_URL=tcp://docker-proxy:4321 \
  EXPERIMENT=$name \
  SKIP_PUSH=1 \
  ./scripts/experiments.sh
done
```

Що аналізувати:
- `ALGO_DURATION_MS` — час виконання алгоритму.
- Чи зростає прискорення при збільшенні `NUM_WORKERS` зі збільшенням розміру матриці.

### 5) Тест стійкості — вироджена матриця

```bash
LEADER_URL=tcp://docker-proxy:4321 \
NUM_WORKERS=2 \
MATRIX='[[1,2,3,4],[2,4,6,8],[3,6,9,12]]' \
SERVICE_NAME=gauss-singular-test \
SKIP_PUSH=1 \
./scripts/run.sh
```

Очікувано: `singular or near-singular matrix`.

---

## Формат JSON для власних кейсів

```json
{
  "experiments": [
    {
      "name": "my_case",
      "num_workers": 4,
      "matrix": [[2, 1, -1, 8], [-3, -1, 2, -11], [-2, 1, 2, -3]]
    },
    {
      "name": "big_case",
      "num_workers": 4,
      "size": 2000,
      "seed": 123
    }
  ]
}
```

Запуск з кастомним файлом:

```bash
LEADER_URL=tcp://docker-proxy:4321 \
INPUT_JSON=./my-experiments.json \
SKIP_PUSH=1 \
./scripts/experiments.sh
```

---

## Мінімальний шаблон для звіту

Для кожного запуску зафіксуй:
- назву кейсу,
- `NUM_WORKERS`,
- розмір матриці або `SIZE`,
- `ALGO_DURATION_MS`,
- статус (успішно / помилка),
- перші / останні кілька значень вектора `x`.
