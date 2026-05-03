package main

import (
	"encoding/json"
	"fmt"
	"github.com/lionell/parcs/go/parcs"
	"log"
	"math"
	"math/rand"
	"os"
	"strconv"
	"sync"
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
	Done     bool        `json:"done"`
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
	if raw := os.Getenv("MATRIX"); raw != "" {
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

	sizeStr := os.Getenv("SIZE")
	if sizeStr == "" {
		log.Fatal("either MATRIX or SIZE env var is required")
	}
	n, err := strconv.Atoi(sizeStr)
	if err != nil || n <= 0 {
		log.Fatalf("invalid SIZE value %q", sizeStr)
	}

	seed := int64(42)
	if seedStr := os.Getenv("SEED"); seedStr != "" {
		if s, err := strconv.ParseInt(seedStr, 10, 64); err == nil {
			seed = s
		}
	}

	log.Printf("Generating random %dx%d diagonally dominant matrix (seed=%d)", n, n, seed)
	return generateMatrix(n, seed)
}

// generateMatrix produces a random diagonally dominant augmented matrix [A|b].
// Diagonal dominance guarantees the system is non-singular.
// Off-diagonal values are integers in [-5, 5]; b values are integers in [-100, 100].
func generateMatrix(n int, seed int64) [][]float64 {
	rng := rand.New(rand.NewSource(seed))
	matrix := make([][]float64, n)
	for i := range matrix {
		matrix[i] = make([]float64, n+1)
		rowAbsSum := 0.0
		for j := 0; j < n; j++ {
			if j != i {
				v := float64(rng.Intn(11) - 5)
				matrix[i][j] = v
				rowAbsSum += math.Abs(v)
			}
		}
		// Diagonal strictly greater than the sum of off-diagonal absolute values.
		matrix[i][i] = rowAbsSum + float64(rng.Intn(10)+1)
		matrix[i][n] = float64(rng.Intn(201) - 100)
	}
	return matrix
}

// forwardEliminationParallel performs the forward elimination phase using
// long-lived PARCS workers. Workers are started once and reused across all
// pivot steps, avoiding per-step container start/stop overhead. Communication
// with workers at each step happens concurrently via goroutines.
func forwardEliminationParallel(runner *parcs.Runner, matrix [][]float64, workerImage string, numWorkers int) (retErr error) {
	tasks := make([]*parcs.Task, numWorkers)
	for i := 0; i < numWorkers; i++ {
		task, err := runner.Start(workerImage)
		if err != nil {
			shutdownStartedTasks(tasks[:i])
			return fmt.Errorf("start worker %d: %w", i, err)
		}
		tasks[i] = task
	}
	defer func() {
		if err := shutdownStartedTasks(tasks); err != nil && retErr == nil {
			retErr = err
		}
	}()

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

		// Always distribute work across all numWorkers; chunks may be empty
		// for workers when rowsBelow count is less than numWorkers.
		chunks := splitRows(rowsBelow, numWorkers)

		offsets := make([]int, numWorkers)
		off := 0
		for i := 0; i < numWorkers; i++ {
			offsets[i] = off
			off += len(chunks[i])
		}

		// Send tasks to all workers concurrently.
		sendErrs := make([]error, numWorkers)
		var wg sync.WaitGroup
		for i := 0; i < numWorkers; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				payload := EliminationTask{
					PivotRow: matrix[k],
					PivotCol: k,
					Rows:     chunks[i],
				}
				sendErrs[i] = tasks[i].Send(payload)
			}(i)
		}
		wg.Wait()
		for i, err := range sendErrs {
			if err != nil {
				return fmt.Errorf("send to worker %d: %w", i, err)
			}
		}

		// Receive results from all workers concurrently.
		results := make([]EliminationResult, numWorkers)
		recvErrs := make([]error, numWorkers)
		for i := 0; i < numWorkers; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				recvErrs[i] = tasks[i].Recv(&results[i])
			}(i)
		}
		wg.Wait()
		for i, err := range recvErrs {
			if err != nil {
				return fmt.Errorf("recv from worker %d: %w", i, err)
			}
		}

		for i := 0; i < numWorkers; i++ {
			for j := range results[i].Rows {
				matrix[k+1+offsets[i]+j] = results[i].Rows[j]
			}
		}
	}

	// Signal all workers to stop before shutdown.
	for i := 0; i < numWorkers; i++ {
		if err := tasks[i].Send(EliminationTask{Done: true}); err != nil {
			return fmt.Errorf("send done to worker %d: %w", i, err)
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

func main() {
	parcs.Exec(&Program{Runner: parcs.DefaultRunner()})
}
