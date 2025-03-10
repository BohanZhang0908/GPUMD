#include <iostream>
#include <cuda_runtime.h>

#define CHECK_CUDA_ERROR(call)                                           \
    do {                                                                 \
        cudaError_t err = call;                                          \
        if (err != cudaSuccess) {                                        \
            std::cerr << "CUDA Error: " << cudaGetErrorString(err)       \
                      << " (err_num=" << err << ") at " << __FILE__      \
                      << ":" << __LINE__ << std::endl;                   \
            exit(EXIT_FAILURE);                                          \
        }                                                                \
    } while (0)


// -------------------------------------------
// - A_d：整型数组，大小 n，存放 type_sum (每种原子类型的个数)
// - b_d：单个 double，存放 energy_ref (总能量)
// - x_d：double 数组，大小 n，输出每种类型对应的能量 E[i]
// - n  ：类型数 num_types
//
// 数学公式：
//   E_i = (A[i] * b) / ( ∑(A[j]^2) )    (j=0..n-1)
// -------------------------------------------
__global__
void kernelComputePseudoInverse1xN(const int* A_d, 
                                   const float* b_d, 
                                   float* x_d,
                                   int n)
{
    __shared__ float sum_of_squares;

    // 线程0 串行计算 ∑(A[j]^2)，并写入 sum_of_squares
    if (threadIdx.x == 0) {
        float tmp = 0.0f;
        for(int i = 0; i < n; i++){
            float val = static_cast<float>(A_d[i]);
            tmp += val * val;
        }
        sum_of_squares = tmp;
    }
    __syncthreads();

    // 每个线程计算 x_d[i] = (A_d[i] * b) / sum_of_squares
    int i = threadIdx.x;
    if (i < n) {
        float val_i = static_cast<float>(A_d[i]);
        float b_val = b_d[0];
        x_d[i] = (val_i * b_val) / sum_of_squares;
    }
}

__global__
void kernelComputePseudoInverseReg1xN(const int* A_d,
                                      const float* b_d,
                                      const float* lambda_d, // 分母加入l2正则化
                                      float* x_d,
                                      int n)
{
    __shared__ float sum_of_squares;

    // (1) 线程0 计算 ∑(A_d[j]^2)
    if (threadIdx.x == 0) {
        float tmp = 0.0f;
        for(int j = 0; j < n; j++) {
            float val = static_cast<float>(A_d[j]);
            tmp += val * val;
        }
        sum_of_squares = tmp;
    }
    __syncthreads();

    // (2) 每个线程计算 x_d[i]
    int i = threadIdx.x;
    if (i < n) {
        float val_i = static_cast<float>(A_d[i]);  // type_sum[i]
        float b_val = b_d[0];                       // energy_ref
        float lambda_val = lambda_d[0];             // λ

        // 分母: sum_of_squares + λ
        x_d[i] = (val_i * b_val) / (sum_of_squares + lambda_val);
    }
}


// -------------------------------------------
// 封装函数：在 GPU 上计算每种类型的能量 E[i]
// 输入：
//  - num_types           : 原子类型数
//  - type_sum[]     : 整型数组(长度 num_types)，各类型原子个数
//  - energy_ref     : 总能量 (float)
// 输出：
//  - energy_per_type[] : float 数组(长度 num_types)，每种类型的能量
// -------------------------------------------
void computeEnergyPerType(int num_types, 
                              const int* type_sum,
                              float energy_ref,
                              float* energy_per_type)
{
    // int* A_d = nullptr;
    float *b_d = nullptr;
    // float *x_d = nullptr;

    // CHECK_CUDA_ERROR(cudaMalloc((void**)&A_d, sizeof(int) * num_types));
    CHECK_CUDA_ERROR(cudaMalloc((void**)&b_d, sizeof(float)));
    // CHECK_CUDA_ERROR(cudaMalloc((void**)&x_d, sizeof(float) * num_types));

    // CHECK_CUDA_ERROR(cudaMemcpy(A_d, type_sum, 
    //                             sizeof(int)*num_types,
    //                             cudaMemcpyHostToDevice));
    CHECK_CUDA_ERROR(cudaMemcpy(b_d, &energy_ref,
                                sizeof(float),
                                cudaMemcpyHostToDevice));

    dim3 block(num_types);
    dim3 grid(1);
    kernelComputePseudoInverse1xN<<<grid, block>>>(type_sum, b_d, energy_per_type, num_types);
    CHECK_CUDA_ERROR(cudaDeviceSynchronize());

    // CHECK_CUDA_ERROR(cudaMemcpy(energy_per_type, x_d, 
    //                             sizeof(float)*num_types,
    //                             cudaMemcpyDeviceToHost));

    // CHECK_CUDA_ERROR(cudaFree(A_d));
    CHECK_CUDA_ERROR(cudaFree(b_d));
    // CHECK_CUDA_ERROR(cudaFree(x_d));
}

void computeEnergyPerTypeReg(int num_types,
                                 const int* type_sum,
                                 float energy_ref,
                                 float lambda, 
                                 float* energy_per_type)
{
    // int* A_d = nullptr;
    float *b_d = nullptr, *lambda_d = nullptr;
    // float *x_d = nullptr;
    // CHECK_CUDA_ERROR(cudaMalloc((void**)&A_d,     sizeof(int) * num_types));
    CHECK_CUDA_ERROR(cudaMalloc((void**)&b_d,     sizeof(float)));
    CHECK_CUDA_ERROR(cudaMalloc((void**)&lambda_d,sizeof(float)));
    // CHECK_CUDA_ERROR(cudaMalloc((void**)&x_d,     sizeof(float) * num_types));

    // CHECK_CUDA_ERROR(cudaMemcpy(A_d, type_sum,
    //                             sizeof(int)*num_types,
    //                             cudaMemcpyHostToDevice));
    CHECK_CUDA_ERROR(cudaMemcpy(b_d, &energy_ref,
                                sizeof(float),
                                cudaMemcpyHostToDevice));
    CHECK_CUDA_ERROR(cudaMemcpy(lambda_d, &lambda,
                                sizeof(float),
                                cudaMemcpyHostToDevice));

    dim3 block(num_types);
    dim3 grid(1);
    kernelComputePseudoInverseReg1xN<<<grid, block>>>(type_sum, b_d, lambda_d, energy_per_type, num_types);
    CHECK_CUDA_ERROR(cudaDeviceSynchronize());

    // CHECK_CUDA_ERROR(cudaMemcpy(energy_per_type, x_d,
    //                             sizeof(float)*num_types,
    //                             cudaMemcpyDeviceToHost));

    // CHECK_CUDA_ERROR(cudaFree(A_d));
    CHECK_CUDA_ERROR(cudaFree(b_d));
    CHECK_CUDA_ERROR(cudaFree(lambda_d));
    // CHECK_CUDA_ERROR(cudaFree(x_d));
}
