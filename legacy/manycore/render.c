/* Each worker writes its own bank. Host interleaves the banks into scan order.
 * No library, global variables, heap, multiply, divide or floating point needed.
 * Pixel format: 0x00RRGGBB. */
void kernel(unsigned tid, unsigned workers, volatile unsigned *out)
{
    for (unsigned p = tid; p < 64u * 64u; p += workers) {
        unsigned x = p & 63u, y = p >> 6;
        unsigned checker = ((x >> 3) ^ (y >> 3)) & 1u;
        unsigned r = x << 2, g = y << 2, b = checker ? 224u : 32u;
        /* A central diamond exercises worker-dependent conditional paths. */
        unsigned dx = x > 31 ? x - 31 : 31 - x;
        unsigned dy = y > 31 ? y - 31 : 31 - y;
        if (dx + dy < 16) { r = 255; g = 192; b = 32; }
        *out++ = (r << 16) | (g << 8) | b;
    }
}
