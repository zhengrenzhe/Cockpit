#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
  int inherited[256] = {0};
  for (int descriptor = 0; descriptor < 256; descriptor++) {
    errno = 0;
    inherited[descriptor] =
        fcntl(descriptor, F_GETFD) >= 0 || errno != EBADF;
  }

  FILE *output = stdout;
  if (argc > 1) {
    output = fopen(argv[1], "w");
    if (output == NULL) return 3;
  }
  for (int descriptor = 0; descriptor < 256; descriptor++) {
    if (inherited[descriptor]) {
      fprintf(output, "fd=%d\n", descriptor);
    }
  }
  fprintf(output, "pid=%d pgid=%d sid=%d cwd=", getpid(), getpgrp(), getsid(0));
  char path[4096];
  if (getcwd(path, sizeof(path)) == NULL) return 2;
  fprintf(output, "%s\n", path);
  fflush(output);
  if (output != stdout) fclose(output);
  if (argc > 2) {
    sleep((unsigned int)strtoul(argv[2], NULL, 10));
  } else {
    usleep(250000);
  }
  return 0;
}
