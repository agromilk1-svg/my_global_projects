#include <stdio.h>

int apply_coretrust_bypass(const char *machoPath) {
  printf("[Stub] check_coretrust_bypass called for %s - Skipping CT bypass "
         "(OpenSSL missing)\n",
         machoPath);
  // Return 0 to indicate success (so installation proceeds)
  // The binary will remain ad-hoc signed by ldid.
  return 0;
}
