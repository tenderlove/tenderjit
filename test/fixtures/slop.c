#include <stdio.h>
#include <stdlib.h>

struct hello {
    char *p;
    char c;
    long x;
};

int main(int argc, char **argv) {
  struct hello * m;
  m = malloc(sizeof(struct hello));
  m->c = 123;
  m->x = 123;
  printf("Hello World %lu\n", m->x);
  return 0;
}
