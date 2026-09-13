# the port refuses the filesystem rather than pretending: open() must raise io_error
open('/etc/passwd', 'r')
