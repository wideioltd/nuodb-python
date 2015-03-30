# -*- coding: utf-8 -*-
from distutils.core import setup
from Cython.Build import cythonize

setup(
    name='pynuodb',
    version='2.2',
    author='NuoDB',
    author_email='info@nuodb.com',
    description='NuoDB Python driver',
    keywords='nuodb scalable cloud database',
    packages=['pynuodb'],
    ext_modules = cythonize("pynuodb/encodedsession.pyx"),    
    package_dir={'pynuodb': 'pynuodb'},
    package_data={'pynuodb': ['*.c']},
#    data_files=[('lib', ['rc4impl.c']),
    url='https://github.com/nuodb/nuodb-python',
    license='BSD licence, see LICENCE.txt',
    long_description=open('README.md').read(),
)

