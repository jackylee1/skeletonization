#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "cpu.hpp"
#include "../common/cpu_only_utils.hpp"
#include "../common/utils.hpp"

// Computes the number of black neighbors around a pixel.
uint8_t black_neighbors_around(uint8_t* data, int row, int col, unsigned int width, unsigned int height) {
    uint8_t count = 0;

    count += (P2_f(data, row, col, width, height) == BINARY_BLACK);
    count += (P3_f(data, row, col, width, height) == BINARY_BLACK);
    count += (P4_f(data, row, col, width, height) == BINARY_BLACK);
    count += (P5_f(data, row, col, width, height) == BINARY_BLACK);
    count += (P6_f(data, row, col, width, height) == BINARY_BLACK);
    count += (P7_f(data, row, col, width, height) == BINARY_BLACK);
    count += (P8_f(data, row, col, width, height) == BINARY_BLACK);
    count += (P9_f(data, row, col, width, height) == BINARY_BLACK);

    return count;
}

uint8_t P2_f(uint8_t* data, int row, int col, unsigned int width, unsigned int height) {
    return is_outside_image(row, col, width, height) ? BINARY_WHITE : data[(row - 1) * width + col];
}

uint8_t P3_f(uint8_t* data, int row, int col, unsigned int width, unsigned int height) {
    return is_outside_image(row, col, width, height) ? BINARY_WHITE : data[(row - 1) * width + (col - 1)];
}

uint8_t P4_f(uint8_t* data, int row, int col, unsigned int width, unsigned int height) {
    return is_outside_image(row, col, width, height) ? BINARY_WHITE : data[row * width + (col - 1)];
}

uint8_t P5_f(uint8_t* data, int row, int col, unsigned int width, unsigned int height) {
    return is_outside_image(row, col, width, height) ? BINARY_WHITE : data[(row + 1) * width + (col - 1)];
}

uint8_t P6_f(uint8_t* data, int row, int col, unsigned int width, unsigned int height) {
    return is_outside_image(row, col, width, height) ? BINARY_WHITE : data[(row + 1) * width + col];
}

uint8_t P7_f(uint8_t* data, int row, int col, unsigned int width, unsigned int height) {
    return is_outside_image(row, col, width, height) ? BINARY_WHITE : data[(row + 1) * width + (col + 1)];
}

uint8_t P8_f(uint8_t* data, int row, int col, unsigned int width, unsigned int height) {
    return is_outside_image(row, col, width, height) ? BINARY_WHITE : data[row * width + (col + 1)];
}

uint8_t P9_f(uint8_t* data, int row, int col, unsigned int width, unsigned int height) {
    return is_outside_image(row, col, width, height) ? BINARY_WHITE : data[(row - 1) * width + (col + 1)];
}

// Performs an image skeletonization algorithm on the input Bitmap, and stores
// the result in the output Bitmap.
unsigned int skeletonize(Bitmap** src_bitmap, Bitmap** dst_bitmap) {
    unsigned int iterations = 0;

    do {
        skeletonize_pass((*src_bitmap)->data, (*dst_bitmap)->data, (*src_bitmap)->width, (*src_bitmap)->height);
        swap_bitmaps((void**) src_bitmap, (void**) dst_bitmap);

        iterations++;
        printf(".");
        fflush(stdout);
    } while (!are_identical_bitmaps(*src_bitmap, *dst_bitmap));

    return iterations;
}

// Performs 1 iteration of the thinning algorithm.
void skeletonize_pass(uint8_t* src, uint8_t* dst, unsigned int width, unsigned int height) {
    for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
            // Optimization for CPU algorithm: You don't need to do any of these
            // computations if the pixel is already BINARY_WHITE
            if (src[row * width + col] == BINARY_BLACK) {
                uint8_t NZ = black_neighbors_around(src, row, col, width, height);
                uint8_t TR_P1 = wb_transitions_around(src, row, col, width, height);
                uint8_t TR_P2 = wb_transitions_around(src, row - 1, col, width, height);
                uint8_t TR_P4 = wb_transitions_around(src, row, col - 1, width, height);
                uint8_t P2 = P2_f(src, row, col, width, height);
                uint8_t P4 = P4_f(src, row, col, width, height);
                uint8_t P6 = P6_f(src, row, col, width, height);
                uint8_t P8 = P8_f(src, row, col, width, height);

                uint8_t thinning_cond_1 = ((2 <= NZ) && (NZ <= 6));
                uint8_t thinning_cond_2 = (TR_P1 == 1);
                uint8_t thinning_cond_3 = (((P2 && P4 && P8) == 0) || (TR_P2 != 1));
                uint8_t thinning_cond_4 = (((P2 && P4 && P6) == 0) || (TR_P4 != 1));

                if (thinning_cond_1 && thinning_cond_2 && thinning_cond_3 && thinning_cond_4) {
                    dst[row * width + col] = BINARY_WHITE;
                } else {
                    dst[row * width + col] = src[row * width + col];
                }
            } else {
                dst[row * width + col] = src[row * width + col];
            }
        }
    }
}

// Computes the number of white to black transitions around a pixel.
uint8_t wb_transitions_around(uint8_t* data, int row, int col, unsigned int width, unsigned int height) {
    uint8_t count = 0;

    count += ( (P2_f(data, row, col, width, height) == BINARY_WHITE) && (P3_f(data, row, col, width, height) == BINARY_BLACK) );
    count += ( (P3_f(data, row, col, width, height) == BINARY_WHITE) && (P4_f(data, row, col, width, height) == BINARY_BLACK) );
    count += ( (P4_f(data, row, col, width, height) == BINARY_WHITE) && (P5_f(data, row, col, width, height) == BINARY_BLACK) );
    count += ( (P5_f(data, row, col, width, height) == BINARY_WHITE) && (P6_f(data, row, col, width, height) == BINARY_BLACK) );
    count += ( (P6_f(data, row, col, width, height) == BINARY_WHITE) && (P7_f(data, row, col, width, height) == BINARY_BLACK) );
    count += ( (P7_f(data, row, col, width, height) == BINARY_WHITE) && (P8_f(data, row, col, width, height) == BINARY_BLACK) );
    count += ( (P8_f(data, row, col, width, height) == BINARY_WHITE) && (P9_f(data, row, col, width, height) == BINARY_BLACK) );
    count += ( (P9_f(data, row, col, width, height) == BINARY_WHITE) && (P2_f(data, row, col, width, height) == BINARY_BLACK) );

    return count;
}

int main(int argc, char** argv) {
    Bitmap* src_bitmap = NULL;
    Bitmap* dst_bitmap = NULL;

    cpu_pre_skeletonization(argc, argv, &src_bitmap, &dst_bitmap);

    unsigned int iterations = skeletonize(&src_bitmap, &dst_bitmap);
    printf(" %u iterations\n", iterations);

    cpu_post_skeletonization(argv, &src_bitmap, &dst_bitmap);

    return EXIT_SUCCESS;
}
