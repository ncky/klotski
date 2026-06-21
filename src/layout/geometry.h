#ifndef KLOTSKI_LAYOUT_GEOMETRY_H
#define KLOTSKI_LAYOUT_GEOMETRY_H

typedef struct kl_rect {
    double x;
    double y;
    double width;
    double height;
} kl_rect_t;

typedef struct kl_point {
    double x;
    double y;
} kl_point_t;

static inline double kl_max_double(double a, double b)
{
    return a > b ? a : b;
}

static inline double kl_min_double(double a, double b)
{
    return a < b ? a : b;
}

static inline double kl_clamp_double(double value, double min, double max)
{
    return kl_min_double(kl_max_double(value, min), max);
}

#endif
