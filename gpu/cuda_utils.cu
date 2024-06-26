#include <cuda_runtime.h>
#include <iostream>
#include <cublas_v2.h>
#include <float.h>
#include "cuda_utils.h"

#define CEIL_DIV(a, b) (((a) + (b) - 1) / (b))

// CUDA kernel for matrix multiplication with A and transpose(B)
__global__ void matMulCudaKernelNaive(float* A, float* B, float* C, int aRows, int aCols, int bRows) {
    int row = blockIdx.y * blockDim.y + threadIdx.y;
    int col = blockIdx.x * blockDim.x + threadIdx.x;

    if (row < aRows && col < bRows) {
        float value = 0;
        for (int k = 0; k < aCols; ++k) {
            // B is accessed in transposed manner
            value += A[row * aCols + k] * B[col * aCols + k];
        }
        C[row * bRows + col] = value;
    }
}

extern "C" void matMulCUDANaive(float* a, int aRows, int aCols, float* b, int bRows, int bCols, float* out) {
    float *d_A, *d_B, *d_C;
    size_t sizeA = aRows * aCols * sizeof(float);
    size_t sizeB = bRows * bCols * sizeof(float);
    size_t sizeC = aRows * bRows * sizeof(float);

    cudaMalloc((void**)&d_A, sizeA);
    cudaMalloc((void**)&d_B, sizeB);
    cudaMalloc((void**)&d_C, sizeC);

    cudaMemcpy(d_A, a, sizeA, cudaMemcpyHostToDevice);
    cudaMemcpy(d_B, b, sizeB, cudaMemcpyHostToDevice);

    // Cuda Kernel
    dim3 dimBlock(32, 32);
    dim3 dimGrid(CEIL_DIV(bRows, 32), CEIL_DIV(aRows, 32));

    matMulCudaKernelNaive<<<dimGrid, dimBlock>>>(d_A, d_B, d_C, aRows, aCols, bRows);

    cudaMemcpy(out, d_C, sizeC, cudaMemcpyDeviceToHost);
    cudaFree(d_A);
    cudaFree(d_B);
    cudaFree(d_C);
}

// CUDA kernel for matrix multiplication with A and transpose(B)
__global__ void matMulCudaKernelOptimized(float* A, float* B, float* C, int aRows, int aCols, int bRows) {
    const int TILE_SIZE = 32;

    int row = blockIdx.y * blockDim.y + threadIdx.y;
    int col = blockIdx.x * blockDim.x + threadIdx.x;

    __shared__ float As[TILE_SIZE][TILE_SIZE];
    __shared__ float Bs[TILE_SIZE][TILE_SIZE];

    float value = 0;
    // Loop over tiles
    for (int m = 0; m < (aCols - 1) / TILE_SIZE + 1; m++) {
        // Load section of A and B into memory
        if (m * TILE_SIZE + threadIdx.x < aCols && row < aRows) {
            As[threadIdx.y][threadIdx.x] = A[row * aCols + m * TILE_SIZE + threadIdx.x];
        } else {
            // Ensure sum not affected
            As[threadIdx.y][threadIdx.x] = 0.0;
        }
        if (m * TILE_SIZE + threadIdx.y < aCols && col < bRows) {
            Bs[threadIdx.y][threadIdx.x] = B[col * aCols + m * TILE_SIZE + threadIdx.y];
        } else {
            Bs[threadIdx.y][threadIdx.x] = 0.0;
        }

        // Prevent overwrite to shmem
        __syncthreads();

        for (int k = 0; k < TILE_SIZE; k++) {
            value += As[threadIdx.y][k] * Bs[k][threadIdx.x];
        }
        __syncthreads();
    }

    if (row < aRows && col < bRows) {
        C[row * bRows + col] = value;
    }
}

extern "C" void matMulCUDA(float* a, int aRows, int aCols, float* b, int bRows, int bCols, float* out) {
    // Cuda Kernel
    dim3 dimBlock(32, 32);
    dim3 dimGrid(CEIL_DIV(bRows, 32), CEIL_DIV(aRows, 32));
    matMulCudaKernelOptimized<<<dimGrid, dimBlock>>>(a, b, out, aRows, aCols, bRows);
}

// Cublas for matrix multiplication with A and transpose(B)
extern "C" void matMulCublas(float* a, int aRows, int aCols, float* b, int bRows, int bCols, float* out) {
    cublasHandle_t handle;
    cublasCreate(&handle);

    float *d_A, *d_B, *d_C;
    size_t sizeA = aRows * aCols * sizeof(float);
    size_t sizeB = bRows * bCols * sizeof(float);
    size_t sizeC = aRows * bRows * sizeof(float);

    cudaMalloc((void**)&d_A, sizeA);
    cudaMalloc((void**)&d_B, sizeB);
    cudaMalloc((void**)&d_C, sizeC);

    cudaMemcpy(d_A, a, sizeA, cudaMemcpyHostToDevice);
    cudaMemcpy(d_B, b, sizeB, cudaMemcpyHostToDevice);
    
    // Cublas Kernel
    float one = 1.0;
    float zero = 0.0;

    // We WTG C = A * B.T
    // Cublas stores in column order while C stores in row order
    // So Cublas interprets A and B as A.T and B.T
    // Therefore we input B.T * A -> interpreted as B * A.T = C.T
    // C.T in column major = C in row major, so we have what we want
    cublasSgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N,
                bRows, aRows, aCols, // rows C, cols C, cols op(A)
                &one,
                d_B, bCols, // ld B
                d_A, aCols, // ld A
                &zero, d_C, bRows); // ld C

    cudaMemcpy(out, d_C, sizeC, cudaMemcpyDeviceToHost);

    cudaFree(d_A);
    cudaFree(d_B);
    cudaFree(d_C);
    cublasDestroy(handle);
}

// Brodcasts sum of each row across rows
__global__ void sumCudaKernel(float* input, float* output, int rows, int cols) {
    extern __shared__ float sharedSum[];

    for (int row = blockIdx.x; row < rows; row += gridDim.x) {
        float sum = 0;
        for (int col = threadIdx.x; col < cols; col += blockDim.x) {
            sum += input[row * cols + col];
        }
        sharedSum[threadIdx.x] = sum;

        __syncthreads();

        // Reduction in shared memory
        if (threadIdx.x == 0) {
            float totalSum = 0;
            for (int i = 0; i < blockDim.x; i++) {
                totalSum += sharedSum[i];
            }
            output[row * cols] = totalSum;
        }
        __syncthreads();
    }
}


extern "C" void sumCUDA(Matrix a, Matrix out)
{
    dim3 dimBlock(256, 1);
    dim3 dimGrid(128, 1);
;
    int sharedMemSize = dimBlock.x * sizeof(float);

    sumCudaKernel<<<dimGrid, dimBlock, sharedMemSize>>>(a.dat, out.dat, a.rows, a.cols);
}

// From Lab 2
__global__
void transposeKernel(const float *input, float *output, int rows, int cols) {
    const int TILE_DIM = 64;
    __shared__ float tile[TILE_DIM][TILE_DIM + 1];  // +1 for padding to avoid bank conflicts

    // Global index calculations for reading input
    int xIndex = blockIdx.x * TILE_DIM + threadIdx.x;
    int yIndex = blockIdx.y * TILE_DIM + 4 * threadIdx.y;  // Each thread reads 4 elements along y

    // Local index within shared memory
    int localX = threadIdx.x;
    int localY = threadIdx.y;

    // Read input matrix in a coalesced manner and store into shared memory
    if (xIndex < cols) {
        if (yIndex + 0 < rows) tile[localY * 4 + 0][localX] = input[xIndex + (yIndex + 0) * cols];
        if (yIndex + 1 < rows) tile[localY * 4 + 1][localX] = input[xIndex + (yIndex + 1) * cols];
        if (yIndex + 2 < rows) tile[localY * 4 + 2][localX] = input[xIndex + (yIndex + 2) * cols];
        if (yIndex + 3 < rows) tile[localY * 4 + 3][localX] = input[xIndex + (yIndex + 3) * cols];
    }

    __syncthreads();  // Synchronize to ensure all writes to shared memory are complete

    // Transpose within shared memory
    xIndex = blockIdx.y * TILE_DIM + threadIdx.x;
    yIndex = blockIdx.x * TILE_DIM + 4 * threadIdx.y;

    // Write output in a coalesced manner
    if (xIndex < rows) {
        if (yIndex + 0 < cols) output[(yIndex + 0) * rows + xIndex] = tile[localX][localY * 4 + 0];
        if (yIndex + 1 < cols) output[(yIndex + 1) * rows + xIndex] = tile[localX][localY * 4 + 1];
        if (yIndex + 2 < cols) output[(yIndex + 2) * rows + xIndex] = tile[localX][localY * 4 + 2];
        if (yIndex + 3 < cols) output[(yIndex + 3) * rows + xIndex] = tile[localX][localY * 4 + 3];
    }
}

extern "C" void transposeCUDA_util(Matrix a, Matrix out)
{
    float *d_input, *d_output;
    size_t size = a.rows * a.cols * sizeof(float);

    cudaMalloc(&d_input, size);
    cudaMalloc(&d_output, size);

    cudaMemcpy(d_input, a.dat, size, cudaMemcpyHostToDevice);

    const int TILE_DIM = 64;

    dim3 dimBlock(TILE_DIM, TILE_DIM / 4); // 64x16
    dim3 dimGrid(CEIL_DIV(a.cols, TILE_DIM), CEIL_DIV(a.rows, TILE_DIM));
    

    transposeKernel<<<dimGrid, dimBlock>>>(d_input, d_output, a.rows, a.cols);

    cudaMemcpy(out.dat, d_output, size, cudaMemcpyDeviceToHost);

    cudaFree(d_input);
    cudaFree(d_output);
}

extern "C" void transposeCUDA(Matrix a, Matrix out)
{
    const int TILE_DIM = 64;
    dim3 dimBlock(TILE_DIM, TILE_DIM / 4); // 64x16
    dim3 dimGrid(CEIL_DIV(a.cols, TILE_DIM), CEIL_DIV(a.rows, TILE_DIM));
    transposeKernel<<<dimGrid, dimBlock>>>(a.dat, out.dat, a.rows, a.cols);
}

__global__ void embeddingsKernel(Matrix line, Matrix wpe, int *output, int num_total_tokens, int DIM, Matrix wte) {
     int idx = blockIdx.x * blockDim.x + threadIdx.x;
     int i = idx / DIM;
     int j = idx % DIM;
     if (idx < num_total_tokens * DIM) {
        line.dat[i * DIM + j] = wte.dat[output[i] * DIM + j] + wpe.dat[j * 1024 + i];
     }
}

extern "C" void embeddingsCUDA(Matrix line, Matrix wte, Matrix wpe, int *output, int num_total_tokens, int DIM) {
    int threadsPerBlock = 1024;
    int numBlocks = CEIL_DIV(num_total_tokens * DIM, threadsPerBlock);
    embeddingsKernel<<<numBlocks, threadsPerBlock>>>(line, wpe, output, num_total_tokens, DIM, wte);
}

__device__ static float atomicMax(float* address, float val)
{
    int* address_as_i = (int*) address;
    int old = *address_as_i, assumed;
    do {
        assumed = old;
        old = ::atomicCAS(address_as_i, assumed,
            __float_as_int(::fmaxf(val, __int_as_float(assumed))));
    } while (assumed != old);
    return __int_as_float(old);
}

// From lab 3
__global__
void findMaxKernel(float *out_data, float *max_abs_val, int length) {
    extern __shared__ float sdata[];

    uint thread_idx = blockDim.x * blockIdx.x + threadIdx.x;

    float localMax = -INFINITY;
    while (thread_idx < length) {
        localMax = fmaxf(localMax, out_data[thread_idx]);
        thread_idx += blockDim.x * gridDim.x;
    }
    uint tid = threadIdx.x;
    sdata[tid] = localMax;
    __syncthreads();

    for (uint s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) {
            sdata[tid] = fmaxf(sdata[tid], sdata[tid + s]);
        }
        __syncthreads();
    }

    if (tid == 0) {
        atomicMax(max_abs_val, sdata[0]);
    }
}

__global__
void weightedSampleKernel(float *probs, int *output, double rand_val, int length) {
    double sum = 0.0;
    int tmp = 0;
    while(tmp < length) {
        sum += probs[tmp];
        if (sum >= rand_val) {
            break;
        }
        tmp++;
    }
    *output = tmp;
}

extern "C" void softmaxSampleCUDA(Matrix a, int *out) {
    dim3 dimBlock(256, 1);
    dim3 dimGrid(128, 1);
    int sharedMemSize = dimBlock.x * sizeof(float);

    float *dev_max_val;
    float max_val;
    cudaMalloc(&dev_max_val, sizeof(float));
    cudaMemset(dev_max_val, -10000, sizeof(float));
    findMaxKernel<<<dimGrid, dimBlock, sharedMemSize>>>(a.dat, dev_max_val, a.cols);
    cudaMemcpy(&max_val, dev_max_val, sizeof(float), cudaMemcpyDeviceToHost);
    add_constCUDA(a, -1.0 * max_val);
    mat_expCUDA(a, 1);
    
    float *dev_sum;
    float sum;
    cudaMalloc(&dev_sum, sizeof(float));
    sumCudaKernel<<<dimGrid, dimBlock, dimBlock.x * sizeof(float)>>>(a.dat, dev_sum, a.rows, a.cols);
    cudaMemcpy(&sum, dev_sum, sizeof(float), cudaMemcpyDeviceToHost);
    divide_constCUDA(a, sum);
    
    int *dev_out;
    cudaMalloc(&dev_out, sizeof(int));
    double r = ((double)rand() / RAND_MAX);
    weightedSampleKernel<<<1, 1>>>(a.dat, dev_out, r, a.cols);
    cudaMemcpy(out, dev_out, sizeof(int), cudaMemcpyDeviceToHost);
}
   
//  Matrix fn(Matrix a, float k)
#define UNARY(fn, opr)                                                 \
    __global__ void fn##Kernel_MTP(float* a, int aRows, int aCols, float* out, float k) { \
        int row = blockIdx.y * blockDim.y + threadIdx.y;               \
        int col = blockIdx.x * blockDim.x + threadIdx.x;               \
        if (row < aRows && col < aCols) {                              \
            int i = row * aCols + col;                                 \
            float b = a[i];                                            \
            b += 0;                                                    \
            out[i] = opr;                                              \
        }                                                              \
    }                                                                  \
    extern "C" Matrix fn##CUDA(Matrix m, float k) {                    \
        float* a = m.dat;                                              \
        int aRows = m.rows;                                            \
        int aCols = m.cols;                                            \
        dim3 blockSize(32, 32);                                        \
        dim3 gridSize((aCols + blockSize.x - 1) / blockSize.x,         \
                      (aRows + blockSize.y - 1) / blockSize.y);        \
        fn##Kernel_MTP<<<gridSize, blockSize>>>(a, aRows, aCols, a, k);\
        return m;                                                      \
    }

UNARY(divide_const, b / k)                      // divide by a constant
UNARY(add_const, b + k)                         // add a constant
UNARY(mat_isqrt, 1. / sqrt(b))                  // square root each entry
UNARY(mat_exp, exp(b))                          // exponetiate each entry
UNARY(broadcast, a[(i / aCols) * aCols])  // copy the first column to every column

// Tril is the first of two special functions.
//   a   b   c        exp(a/8) exp(b/8) exp(c/8)
//   d   e   f   ->      0     exp(e/8) exp(f/8)
//   g   h   i           0        0        0
// it's use will be described later
UNARY(tril, (i / k < i % (int)k) ? 0 : exp(b / 8))

// GELU is the activation function used for transformers
UNARY(GELU, b / 2 * (1 + tanh(.7978845 * (b + .044715 * b * b * b))))

#define BINARY(fn, opr)                                                                    \
    __global__ void fn##Kernel_MTP(float* a, int aRows, int aCols, float* b, float* out) { \
        int row = blockIdx.y * blockDim.y + threadIdx.y;                                   \
        int col = blockIdx.x * blockDim.x + threadIdx.x;                                   \
        if (row < aRows && col < aCols) {                                                  \
            int i = row * aCols + col;                                                     \
            a[i] = a[i] opr b[i];                                                          \
        }                                                                                  \
    }                                                                                      \
    extern "C" Matrix fn##CUDA(Matrix a, Matrix b) {                                       \
        dim3 blockSize(32, 32);                                                            \
        dim3 gridSize((a.cols + blockSize.x - 1) / blockSize.x,                            \
                      (a.rows + blockSize.y - 1) / blockSize.y);                           \
        fn##Kernel_MTP<<<gridSize, blockSize>>>(a.dat, a.rows, a.cols, b.dat, a.dat);      \
        return a;                                                                          \
    }

BINARY(add, +)       // add two matrices together
BINARY(multiply, *)  // multiply two matrices together
BINARY(divide, /)    // divide the first matrix by the second

// We also have some ugly hacks here to implement "tiling"
// that lets us add or multiply one matrix by the first column of a second
// To do this tiling, we don't want to operate on b.dat[i], so instead
// we re-index with what we want and then just stick a ; there to
// drop the actual b.dat[i]
BINARY(add_tile, +b[i % aCols];(void))
BINARY(multiply_tile, *b[i % aCols];(void))