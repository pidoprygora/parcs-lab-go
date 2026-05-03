package main

import (
	"github.com/lionell/parcs/go/parcs"
	"log"
	"math"
)

const epsilon = 1e-12

type GaussWorker struct {
	*parcs.Service
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

func (w *GaussWorker) Run() {
	for {
		var task EliminationTask
		if err := w.Recv(&task); err != nil {
			log.Fatalf("failed to receive elimination task: %v", err)
		}

		if task.Done {
			return
		}

		if len(task.Rows) == 0 {
			if err := w.Send(EliminationResult{}); err != nil {
				log.Fatalf("failed to send empty elimination result: %v", err)
			}
			continue
		}

		if task.PivotCol < 0 || task.PivotCol >= len(task.PivotRow) {
			log.Fatalf("invalid pivot column %d for pivot row of size %d", task.PivotCol, len(task.PivotRow))
		}

		pivotValue := task.PivotRow[task.PivotCol]
		if math.Abs(pivotValue) < epsilon {
			log.Fatalf("pivot value is too close to zero: %v", pivotValue)
		}

		for i := range task.Rows {
			if task.PivotCol >= len(task.Rows[i]) {
				log.Fatalf("row %d has insufficient width: %d", i, len(task.Rows[i]))
			}

			factor := task.Rows[i][task.PivotCol] / pivotValue
			for j := task.PivotCol; j < len(task.Rows[i]); j++ {
				task.Rows[i][j] -= factor * task.PivotRow[j]
			}

			// Reduce floating-point noise near zero after elimination.
			for j := task.PivotCol; j < len(task.Rows[i]); j++ {
				if math.Abs(task.Rows[i][j]) < epsilon {
					task.Rows[i][j] = 0
				}
			}
		}

		result := EliminationResult{Rows: task.Rows}
		if err := w.Send(result); err != nil {
			log.Fatalf("failed to send elimination result: %v", err)
		}
	}
}

func main() {
	parcs.Exec(&GaussWorker{Service: parcs.DefaultService()})
}
