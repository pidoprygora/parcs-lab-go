package main

import (
	"encoding/json"
	"fmt"
	"github.com/lionell/parcs/go/parcs"
	"log"
	"math"
	"os"
	"strconv"
	"time"
)

const (
	defaultWorkers = 2
	epsilon        = 1e-12
)

type Program struct {
	*parcs.Runner
}

type EliminationTask struct {
	PivotRow []float64   `json:"pivot_row"`
	PivotCol int         `json:"pivot_col"`
	Rows     [][]float64 `json:"rows"`
}

type EliminationResult struct {
	Rows [][]float64 `json:"rows"`
}

func (p *Program) Run() {
	workerImage := os.Getenv("WORKER_IMAGE")
	if workerImage == "" {
		log.Fatal("WORKER_IMAGE env var is required")
	}

	numWorkers := parseNumWorkers()
	matrix := parseAugmentedMatrix()
	n := len(matrix)
	log.Printf("Solving %dx%d system with %d workers", n, n, numWorkers)

	algoStart := time.Now()
	if err := forwardEliminationParallel(p.Runner, matrix, workerImage, numWorkers); err != nil {
		log.Fatalf("forward elimination failed: %v", err)
	}

	solution, err := backwardSubstitution(matrix)
	if err != nil {
		log.Fatalf("backward substitution failed: %v", err)
	}

	log.Println("=== Solution ===")
	roundedSolution := make([]float64, len(solution))
	for i, value := range solution {
		roundedValue := math.Round(value*100) / 100
		roundedSolution[i] = roundedValue
		log.Printf("x[%d] = %.2f", i, roundedValue)
	}
	log.Printf("ALGO_DURATION_MS=%d", time.Since(algoStart).Milliseconds())
	if encoded, err := json.Marshal(roundedSolution); err == nil {
		log.Printf("SOLUTION_JSON=%s", string(encoded))
	}
}

func parseNumWorkers() int {
	raw := os.Getenv("NUM_WORKERS")
	if raw == "" {
		return defaultWorkers
	}

	numWorkers, err := strconv.Atoi(raw)
	if err != nil || numWorkers <= 0 {
		log.Fatalf("invalid NUM_WORKERS value %q", raw)
	}
	return numWorkers
}

func parseAugmentedMatrix() [][]float64 {
	raw := os.Getenv("MATRIX")
	if raw == "" {
		log.Fatal("MATRIX env var is required")
	}

	var matrix [][]float64
	if err := json.Unmarshal([]byte(raw), &matrix); err != nil {
		log.Fatalf("failed to parse MATRIX as JSON: %v", err)
	}

	if len(matrix) == 0 {
		log.Fatal("matrix must not be empty")
	}

	n := len(matrix)
	expectedCols := n + 1
	for i := range matrix {
		if len(matrix[i]) != expectedCols {
			log.Fatalf("row %d has %d columns; expected %d for augmented n x (n+1) matrix",
				i, len(matrix[i]), expectedCols)
		}
	}
	return matrix
}

func forwardEliminationParallel(runner *parcs.Runner, matrix [][]float64, workerImage string, numWorkers int) error {
	n := len(matrix)
	for k := 0; k < n; k++ {
		maxIdx := k
		for i := k + 1; i < n; i++ {
			if math.Abs(matrix[i][k]) > math.Abs(matrix[maxIdx][k]) {
				maxIdx = i
			}
		}
		matrix[k], matrix[maxIdx] = matrix[maxIdx], matrix[k]

		pivot := matrix[k][k]
		if math.Abs(pivot) < epsilon {
			return fmt.Errorf("singular or near-singular matrix at pivot %d", k)
		}

		rowsBelow := matrix[k+1:]
		if len(rowsBelow) == 0 {
			continue
		}

		workers := min(numWorkers, len(rowsBelow))
		chunks := splitRows(rowsBelow, workers)
		tasks := make([]*parcs.Task, workers)

		for i := 0; i < workers; i++ {
			task, err := runner.Start(workerImage)
			if err != nil {
				shutdownStartedTasks(tasks)
				return fmt.Errorf("start worker %d: %w", i, err)
			}

			tasks[i] = task
			payload := EliminationTask{
				PivotRow: matrix[k],
				PivotCol: k,
				Rows:     chunks[i],
			}
			if err := task.Send(payload); err != nil {
				shutdownStartedTasks(tasks)
				return fmt.Errorf("send to worker %d: %w", i, err)
			}
		}

		offset := 0
		for i := 0; i < workers; i++ {
			var result EliminationResult
			if err := tasks[i].Recv(&result); err != nil {
				shutdownStartedTasks(tasks)
				return fmt.Errorf("recv from worker %d: %w", i, err)
			}

			for j := range result.Rows {
				matrix[k+1+offset+j] = result.Rows[j]
			}
			offset += len(result.Rows)
		}

		if err := shutdownStartedTasks(tasks); err != nil {
			return err
		}
	}
	return nil
}

func splitRows(rows [][]float64, workers int) [][][]float64 {
	chunks := make([][][]float64, workers)
	base := len(rows) / workers
	remainder := len(rows) % workers
	start := 0
	for i := 0; i < workers; i++ {
		size := base
		if i < remainder {
			size++
		}
		chunks[i] = rows[start : start+size]
		start += size
	}
	return chunks
}

func shutdownStartedTasks(tasks []*parcs.Task) error {
	var firstErr error
	for _, t := range tasks {
		if t == nil {
			continue
		}
		if err := t.Shutdown(); err != nil && firstErr == nil {
			firstErr = fmt.Errorf("shutdown worker: %w", err)
		}
	}
	return firstErr
}

func backwardSubstitution(matrix [][]float64) ([]float64, error) {
	n := len(matrix)
	x := make([]float64, n)
	for i := n - 1; i >= 0; i-- {
		sum := matrix[i][n]
		for j := i + 1; j < n; j++ {
			sum -= matrix[i][j] * x[j]
		}
		if math.Abs(matrix[i][i]) < epsilon {
			return nil, fmt.Errorf("zero diagonal element at row %d during back substitution", i)
		}
		x[i] = sum / matrix[i][i]
	}
	return x, nil
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func main() {
	parcs.Exec(&Program{Runner: parcs.DefaultRunner()})
}
