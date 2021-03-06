#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "gpu4.cuh"
#include "../common/gpu_only_utils.cuh"
#include "../../../common/lspbmp.hpp"
#include "../../../common/utils.hpp"

#define PAD_TOP (2)
#define PAD_LEFT (2)
#define PAD_BOTTOM (1)
#define PAD_RIGHT (1)

void and_reduction(uint8_t* g_equ_data, int g_size, dim3 grid_dim, dim3 block_dim) {
    // iterative reductions of g_equ_data
    // important to have a block size which is a power of 2, because the
    // reduction algorithm depends on this for the /2 at each iteration.
    // This will give an odd number at some iterations if the block size is
    // not a power of 2.
    do {
        int and_reduction_shared_mem_size = block_dim.x * sizeof(uint8_t);
        and_reduction<<<grid_dim, block_dim, and_reduction_shared_mem_size>>>(g_equ_data, g_size);
        gpuErrchk(cudaPeekAtLastError());
        gpuErrchk(cudaDeviceSynchronize());

        g_size = ceil(g_size / ((double) block_dim.x));
        grid_dim.x = (g_size <= block_dim.x) ? 1 : grid_dim.x;
    } while (g_size != 1);
}

__global__ void and_reduction(uint8_t* g_data, int g_size) {
    // shared memory for tile
    extern __shared__ uint8_t s_data[];

    int blockReductionIndex = blockIdx.x;
    int i = blockIdx.x * blockDim.x + threadIdx.x;

    // Attention : For loop needed here instead of a while loop, because at each
    // iteration there will be work for all threads. A while loop wouldn't allow
    // you to do this.
    int num_iterations_needed = ceil(g_size / ((double) (blockDim.x * gridDim.x)));
    for (int iteration = 0; iteration < num_iterations_needed; iteration++) {
        // Load equality values into shared memory tile. We use 1 as the default
        // value, as it is an AND reduction
        s_data[threadIdx.x] = (i < g_size) ? g_data[i] : 1;
        __syncthreads();

        // do reduction in shared memory
        block_and_reduce(s_data);

        // write result for this block to global memory
        if (threadIdx.x == 0) {
            g_data[blockReductionIndex] = s_data[0];
        }

        blockReductionIndex += gridDim.x;
        i += (gridDim.x * blockDim.x);
    }
}

// Computes the number of black neighbors around a pixel.
__device__ uint8_t black_neighbors_around(uint8_t* s_data, int s_row, int s_col, int s_width) {
    uint8_t count = 0;

    count += (P2_f(s_data, s_row, s_col, s_width) == BINARY_BLACK);
    count += (P3_f(s_data, s_row, s_col, s_width) == BINARY_BLACK);
    count += (P4_f(s_data, s_row, s_col, s_width) == BINARY_BLACK);
    count += (P5_f(s_data, s_row, s_col, s_width) == BINARY_BLACK);
    count += (P6_f(s_data, s_row, s_col, s_width) == BINARY_BLACK);
    count += (P7_f(s_data, s_row, s_col, s_width) == BINARY_BLACK);
    count += (P8_f(s_data, s_row, s_col, s_width) == BINARY_BLACK);
    count += (P9_f(s_data, s_row, s_col, s_width) == BINARY_BLACK);

    return count;
}

__device__ uint8_t block_and_reduce(uint8_t* s_data) {
    for (int s = (blockDim.x / 2); s > 0; s >>= 1) {
        if (threadIdx.x < s) {
            s_data[threadIdx.x] &= s_data[threadIdx.x + s];
        }
        __syncthreads();
    }

    return s_data[0];
}

__device__ uint8_t border_global_mem_read(uint8_t* g_data, int g_row, int g_col, int g_width, int g_height) {
    return is_outside_image(g_row, g_col, g_width, g_height) ? BINARY_WHITE : g_data[g_row * g_width + g_col];
}

__device__ uint8_t is_outside_image(int g_row, int g_col, int g_width, int g_height) {
    return (g_row < 0) | (g_row > (g_height - 1)) | (g_col < 0) | (g_col > (g_width - 1));
}

__device__ uint8_t is_white(uint8_t* s_src, int s_src_row, int s_src_col, int s_src_width, uint8_t* s_equ, int s_equ_col) {
    s_equ[s_equ_col] = (s_src[s_src_row * s_src_width + s_src_col] == BINARY_WHITE);
    __syncthreads();

    return block_and_reduce(s_equ);
}

__device__ void load_s_src(uint8_t* g_src, int g_row, int g_col, int g_width, int g_height, uint8_t* s_src, int s_row, int s_col, int s_width) {
    if (threadIdx.x == 0) {
        // left
        s_src[(s_row - 2) * s_width + (s_col - 2)] = border_global_mem_read(g_src, g_row - 2, g_col - 2, g_width, g_height);
        s_src[(s_row - 2) * s_width + (s_col - 1)] = border_global_mem_read(g_src, g_row - 2, g_col - 1, g_width, g_height);
        s_src[(s_row - 2) * s_width + s_col] = border_global_mem_read(g_src, g_row - 2, g_col, g_width, g_height);

        s_src[(s_row - 1) * s_width + (s_col - 2)] = border_global_mem_read(g_src, g_row - 1, g_col - 2, g_width, g_height);
        s_src[(s_row - 1) * s_width + (s_col - 1)] = border_global_mem_read(g_src, g_row - 1, g_col - 1, g_width, g_height);
        s_src[(s_row - 1) * s_width + s_col] = border_global_mem_read(g_src, g_row - 1, g_col, g_width, g_height);

        s_src[s_row * s_width + (s_col - 2)] = border_global_mem_read(g_src, g_row, g_col - 2, g_width, g_height);
        s_src[s_row * s_width + (s_col - 1)] = border_global_mem_read(g_src, g_row, g_col - 1, g_width, g_height);
        s_src[s_row * s_width + s_col] = border_global_mem_read(g_src, g_row, g_col, g_width, g_height);

        s_src[(s_row + 1) * s_width + (s_col - 2)] = border_global_mem_read(g_src, g_row + 1, g_col - 2, g_width, g_height);
        s_src[(s_row + 1) * s_width + (s_col - 1)] = border_global_mem_read(g_src, g_row + 1, g_col - 1, g_width, g_height);
        s_src[(s_row + 1) * s_width + s_col] = border_global_mem_read(g_src, g_row + 1, g_col, g_width, g_height);
    } else if (threadIdx.x == (blockDim.x - 1)) {
        // right
        s_src[(s_row - 2) * s_width + s_col] = border_global_mem_read(g_src, g_row - 2, g_col, g_width, g_height);
        s_src[(s_row - 2) * s_width + (s_col + 1)] = border_global_mem_read(g_src, g_row - 2, g_col + 1, g_width, g_height);

        s_src[(s_row - 1) * s_width + s_col] = border_global_mem_read(g_src, g_row - 1, g_col, g_width, g_height);
        s_src[(s_row - 1) * s_width + (s_col + 1)] = border_global_mem_read(g_src, g_row - 1, g_col + 1, g_width, g_height);

        s_src[s_row * s_width + s_col] = border_global_mem_read(g_src, g_row, g_col, g_width, g_height);
        s_src[s_row * s_width + (s_col + 1)] = border_global_mem_read(g_src, g_row, g_col + 1, g_width, g_height);

        s_src[(s_row + 1) * s_width + s_col] = border_global_mem_read(g_src, g_row + 1, g_col, g_width, g_height);
        s_src[(s_row + 1) * s_width + (s_col + 1)] = border_global_mem_read(g_src, g_row + 1, g_col + 1, g_width, g_height);
    } else {
        // center
        s_src[(s_row - 2) * s_width + s_col] = border_global_mem_read(g_src, g_row - 2, g_col, g_width, g_height);

        s_src[(s_row - 1) * s_width + s_col] = border_global_mem_read(g_src, g_row - 1, g_col, g_width, g_height);

        s_src[s_row * s_width + s_col] = border_global_mem_read(g_src, g_row, g_col, g_width, g_height);

        s_src[(s_row + 1) * s_width + s_col] = border_global_mem_read(g_src, g_row + 1, g_col, g_width, g_height);
    }

    __syncthreads();
}

__device__ uint8_t P2_f(uint8_t* s_data, int s_row, int s_col, int s_width) {
    return s_data[(s_row - 1) * s_width + s_col];
}

__device__ uint8_t P3_f(uint8_t* s_data, int s_row, int s_col, int s_width) {
    return s_data[(s_row - 1) * s_width + (s_col - 1)];
}

__device__ uint8_t P4_f(uint8_t* s_data, int s_row, int s_col, int s_width) {
    return s_data[s_row * s_width + (s_col - 1)];
}

__device__ uint8_t P5_f(uint8_t* s_data, int s_row, int s_col, int s_width) {
    return s_data[(s_row + 1) * s_width + (s_col - 1)];
}

__device__ uint8_t P6_f(uint8_t* s_data, int s_row, int s_col, int s_width) {
    return s_data[(s_row + 1) * s_width + s_col];
}

__device__ uint8_t P7_f(uint8_t* s_data, int s_row, int s_col, int s_width) {
    return s_data[(s_row + 1) * s_width + (s_col + 1)];
}

__device__ uint8_t P8_f(uint8_t* s_data, int s_row, int s_col, int s_width) {
    return s_data[s_row * s_width + (s_col + 1)];
}

__device__ uint8_t P9_f(uint8_t* s_data, int s_row, int s_col, int s_width) {
    return s_data[(s_row - 1) * s_width + (s_col + 1)];
}

// Performs an image skeletonization algorithm on the input Bitmap, and stores
// the result in the output Bitmap.
int skeletonize(Bitmap** src_bitmap, Bitmap** dst_bitmap, dim3 grid_dim, dim3 block_dim) {
    // allocate memory on device
    uint8_t* g_src_data = NULL;
    uint8_t* g_dst_data = NULL;
    int g_data_size = (*src_bitmap)->width * (*src_bitmap)->height * sizeof(uint8_t);
    gpuErrchk(cudaMalloc((void**) &g_src_data, g_data_size));
    gpuErrchk(cudaMalloc((void**) &g_dst_data, g_data_size));

    uint8_t* g_equ_data = NULL;
    int g_equ_size = ceil(((*src_bitmap)->width * (*src_bitmap)->height) / ((double) block_dim.x));
    gpuErrchk(cudaMalloc((void**) &g_equ_data, g_equ_size));

    // send data to device
    gpuErrchk(cudaMemcpy(g_src_data, (*src_bitmap)->data, g_data_size, cudaMemcpyHostToDevice));

    uint8_t are_identical_bitmaps = 0;
    int iterations = 0;
    do {
        // copy g_src_data over g_dst_data (GPU <-> GPU transfer, so it has much
        // higher throughput than HOST <-> DEVICE transfers)
        gpuErrchk(cudaMemcpy(g_dst_data, g_src_data, g_data_size, cudaMemcpyDeviceToDevice));

        // set g_equ_data to 1 (GPU <-> GPU transfer, so it has very high
        // throughput)
        gpuErrchk(cudaMemset(g_equ_data, 1, g_equ_size));

        int skeletonize_pass_s_src_size = (block_dim.x + PAD_LEFT + PAD_RIGHT) * (1 + PAD_TOP + PAD_BOTTOM) * sizeof(uint8_t);
        int skeletonize_pass_s_equ_size = block_dim.x * sizeof(uint8_t);
        int skeletonize_pass_shared_mem_size = skeletonize_pass_s_src_size + skeletonize_pass_s_equ_size;
        skeletonize_pass<<<grid_dim, block_dim, skeletonize_pass_shared_mem_size>>>(g_src_data, g_dst_data, g_equ_data, (*src_bitmap)->width, (*src_bitmap)->height);
        gpuErrchk(cudaPeekAtLastError());
        gpuErrchk(cudaDeviceSynchronize());

        and_reduction(g_equ_data, g_equ_size, grid_dim, block_dim);

        // bring reduced bitmap equality information back from device
        gpuErrchk(cudaMemcpy(&are_identical_bitmaps, g_equ_data, 1 * sizeof(uint8_t), cudaMemcpyDeviceToHost));

        swap_bitmaps((void**) &g_src_data, (void**) &g_dst_data);

        iterations++;
        printf(".");
        fflush(stdout);
    } while (!are_identical_bitmaps);

    // bring dst_bitmap back from device
    gpuErrchk(cudaMemcpy((*dst_bitmap)->data, g_dst_data, g_data_size, cudaMemcpyDeviceToHost));

    // free memory on device
    gpuErrchk(cudaFree(g_src_data));
    gpuErrchk(cudaFree(g_dst_data));
    gpuErrchk(cudaFree(g_equ_data));

    return iterations;
}

// Performs 1 iteration of the thinning algorithm.
__global__ void skeletonize_pass(uint8_t* g_src, uint8_t* g_dst, uint8_t* g_equ, int g_src_width, int g_src_height) {
    // shared memory for tile
    extern __shared__ uint8_t s_data[];
    uint8_t* s_src = &s_data[0];
    uint8_t* s_equ = &s_data[(blockDim.x + PAD_LEFT + PAD_RIGHT) * (1 + PAD_TOP + PAD_BOTTOM)];

    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int currentBlockIndex = blockIdx.x;

    int g_size = g_src_width * g_src_height;

    while (tid < g_size) {
        int g_src_row = (tid / g_src_width);
        int g_src_col = (tid % g_src_width);

        int s_src_row = PAD_TOP;
        int s_src_col = threadIdx.x + PAD_LEFT;
        int s_src_width = blockDim.x + PAD_LEFT + PAD_RIGHT;

        int s_equ_col = threadIdx.x;

        // load g_src into shared memory
        load_s_src(g_src, g_src_row, g_src_col, g_src_width, g_src_height, s_src, s_src_row, s_src_col, s_src_width);
        uint8_t is_src_white = is_white(s_src, s_src_row, s_src_col, s_src_width, s_equ, s_equ_col);

        if (!is_src_white) {
            uint8_t NZ = black_neighbors_around(s_src, s_src_row, s_src_col, s_src_width);
            uint8_t TR_P1 = wb_transitions_around(s_src, s_src_row, s_src_col, s_src_width);
            uint8_t TR_P2 = wb_transitions_around(s_src, s_src_row - 1, s_src_col, s_src_width);
            uint8_t TR_P4 = wb_transitions_around(s_src, s_src_row, s_src_col - 1, s_src_width);
            uint8_t P2 = P2_f(s_src, s_src_row, s_src_col, s_src_width);
            uint8_t P4 = P4_f(s_src, s_src_row, s_src_col, s_src_width);
            uint8_t P6 = P6_f(s_src, s_src_row, s_src_col, s_src_width);
            uint8_t P8 = P8_f(s_src, s_src_row, s_src_col, s_src_width);

            uint8_t thinning_cond_1 = ((2 <= NZ) & (NZ <= 6));
            uint8_t thinning_cond_2 = (TR_P1 == 1);
            uint8_t thinning_cond_3 = (((P2 & P4 & P8) == 0) | (TR_P2 != 1));
            uint8_t thinning_cond_4 = (((P2 & P4 & P6) == 0) | (TR_P4 != 1));
            uint8_t thinning_cond_ok = thinning_cond_1 & thinning_cond_2 & thinning_cond_3 & thinning_cond_4;

            uint8_t g_dst_next = (thinning_cond_ok * BINARY_WHITE) + ((1 - thinning_cond_ok) * s_src[s_src_row * s_src_width + s_src_col]);
            __syncthreads();
            g_dst[g_src_row * g_src_width + g_src_col] = g_dst_next;

            // compute and write reduced value of s_equ to g_equ:
            //
            // do the first iteration of g_equ's reduction, since we already have
            // everything available in shared memory. This avoids the and_reduction
            // kernel to have to load (g_src_width * g_src_height) data, but only
            // ceil((g_src_width * g_src_height) / ((double) block_dim.x)), which is
            // much less.
            s_equ[s_equ_col] = (s_src[s_src_row * s_src_width + s_src_col] == g_dst_next);
            __syncthreads();
            uint8_t g_equ_next = block_and_reduce(s_equ);
            if (s_equ_col == 0) {
                g_equ[currentBlockIndex] = g_equ_next;
            }
        }

        currentBlockIndex += gridDim.x;
        tid += (gridDim.x * blockDim.x);
    }
}

// Computes the number of white to black transitions around a pixel.
__device__ uint8_t wb_transitions_around(uint8_t* s_data, int s_row, int s_col, int s_width) {
    uint8_t count = 0;

    count += ((P2_f(s_data, s_row, s_col, s_width) == BINARY_WHITE) & (P3_f(s_data, s_row, s_col, s_width) == BINARY_BLACK));
    count += ((P3_f(s_data, s_row, s_col, s_width) == BINARY_WHITE) & (P4_f(s_data, s_row, s_col, s_width) == BINARY_BLACK));
    count += ((P4_f(s_data, s_row, s_col, s_width) == BINARY_WHITE) & (P5_f(s_data, s_row, s_col, s_width) == BINARY_BLACK));
    count += ((P5_f(s_data, s_row, s_col, s_width) == BINARY_WHITE) & (P6_f(s_data, s_row, s_col, s_width) == BINARY_BLACK));
    count += ((P6_f(s_data, s_row, s_col, s_width) == BINARY_WHITE) & (P7_f(s_data, s_row, s_col, s_width) == BINARY_BLACK));
    count += ((P7_f(s_data, s_row, s_col, s_width) == BINARY_WHITE) & (P8_f(s_data, s_row, s_col, s_width) == BINARY_BLACK));
    count += ((P8_f(s_data, s_row, s_col, s_width) == BINARY_WHITE) & (P9_f(s_data, s_row, s_col, s_width) == BINARY_BLACK));
    count += ((P9_f(s_data, s_row, s_col, s_width) == BINARY_WHITE) & (P2_f(s_data, s_row, s_col, s_width) == BINARY_BLACK));

    return count;
}

int main(int argc, char** argv) {
    Bitmap* src_bitmap = NULL;
    Bitmap* dst_bitmap = NULL;
    Padding padding_for_thread_count;
    dim3 grid_dim;
    dim3 block_dim;

    gpu_pre_skeletonization(argc, argv, &src_bitmap, &dst_bitmap, &padding_for_thread_count, &grid_dim, &block_dim);

    int iterations = skeletonize(&src_bitmap, &dst_bitmap, grid_dim, block_dim);
    printf(" %u iterations\n", iterations);
    printf("\n");

    gpu_post_skeletonization(argv, &src_bitmap, &dst_bitmap, padding_for_thread_count);

    return EXIT_SUCCESS;
}
