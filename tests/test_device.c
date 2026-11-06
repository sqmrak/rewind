#include "rewind_device.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    assert(strcmp(rewind_device_name("iPhone4,1"), "iPhone 4S") == 0);
    assert(strcmp(rewind_device_name("iPhone3,3"), "iPhone 4") == 0);
    assert(strcmp(rewind_device_name("iPhone6,1"), "iPhone 5s") == 0);
    assert(strcmp(rewind_device_name("iPad2,5"), "iPad mini") == 0);
    assert(strcmp(rewind_device_name("iPad13,18"), "iPad (10th generation)") == 0);
    assert(strcmp(rewind_device_name("iPod5,1"), "iPod touch (5th generation)") == 0);
    assert(strcmp(rewind_device_name("x86_64"), "Simulator") == 0);
    /* an identifier the table does not hold, a near miss, an empty string and a missing one have no name */
    assert(rewind_device_name("iPhone99,1") == NULL);
    assert(rewind_device_name("iPhone4,10") == NULL);
    assert(rewind_device_name("iphone4,1") == NULL);
    assert(rewind_device_name("") == NULL);
    assert(rewind_device_name(NULL) == NULL);
    puts("test_device ok");
    return 0;
}
