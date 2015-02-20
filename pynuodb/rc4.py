import os,sys
from ctypes import cdll,create_string_buffer,string_at

this_dir = os.path.abspath(os.path.dirname(__file__))
rc4_sofile = os.path.join(this_dir, 'rc4.so')
def build_rc4():
    os.system('cd %s; gcc rc4impl.c -c -fPIC -o rc4.o; gcc -shared ./rc4.o -o rc4.so' % this_dir)
if (not os.path.exists(rc4_sofile)) or (os.stat(os.path.join(this_dir, 'rc4impl.c')).st_mtime > os.stat(rc4_sofile).st_mtime):
    build_rc4()
if not os.path.exists(rc4_sofile):
    sys.stderr.write('Failed to build cimpl library with:\n')
    sys.stderr.write('  gcc rc4impl.c -c -fPIC -o rc4.o; gcc -shared ./rc4.o -o rc4.so\n')
    raise Exception('Wrapper library not built.')


rc4_lib=cdll.LoadLibrary(rc4_sofile)

class RC4(object):
    def __init__(self,key):
        self.key=key

    def __enter__(self):
        self.rc4obj = rc4_lib.init_rc4(self.key) 
        return self

    def transform(self,msg):
        message_inplace = create_string_buffer(msg)
        rc4_lib.transform_rc4(self.rc4obj, message_inplace)
        return string_at(message_inplace)

    def __exit__(self, exc_type, exc_value, traceback):
        rc4_lib.free_rc4(self.rc4obj)








def _test_rc4():
    import time

    with RC4("hello") as r:
        a="Bye"
        for j in range(4):
            a=r.transform(a)
            print a

    key="hello"*4
    a="Bye a very long text text text" *4
    print "testing rc4 on 40,000 string of length %d, key len = %d "%(len(a),len(key))
    start_time = time.time()
    for i in range(10000):
        with RC4(key) as r:
            for j in range(4):
                a=r.transform(a)

    end_time = time.time()
    print "took %g seconds"%(end_time - start_time,)


if __name__=="__main__":
    import time
    start_time = time.time()
    for i in range(10):
        _test_rc4()
    end_time = time.time()
    print "total time: %g seconds"%(end_time - start_time,)
