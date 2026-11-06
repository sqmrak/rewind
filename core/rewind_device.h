#ifndef REWIND_DEVICE_H
#define REWIND_DEVICE_H

/* the name people know a device by for the identifier hw.machine gives ("iPhone4,1" is "iPhone 4S"); NULL for an identifier that is not in the table, which a caller shows as
   it is */
const char *rewind_device_name(const char *machine);

#endif
