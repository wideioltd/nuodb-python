#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/*
Usage:
gcc RC4Cipher.c -c -fPIC -o RC4.o
gcc -shared ./RC4.o -o RC4.so
python RC4.py #test 
*/

typedef struct rc4_s {
    unsigned char state[256];
    unsigned char __s1, __s2;
} rc4_t;


rc4_t* init_rc4(char* key, int kl)
{
    rc4_t * rc4 = (rc4_t*)malloc(sizeof(rc4_t));
    if (!rc4)
        exit(-1);

    rc4->__s1 = 0;
    rc4->__s2 = 0;

    unsigned int i; 
    for(i=0;i<256;i++)
        rc4->state[i] = i;

    unsigned char j=0;
    for(i=0;i<256;i++) //i must be int (unsigned char or char is not enough)
    {
        j +=  rc4->state[i] + key[i % kl] ;
        register unsigned char temp = rc4->state[i];
        rc4->state[i] = rc4->state[j];
        rc4->state[j] = temp; 
    }
    return rc4;
}

void transform_rc4(rc4_t * rc4, char* msg, int mlen)
{
    int ci;
    for(ci=0;ci<mlen;ci++){
        //rc4->__s1++; 
        rc4->__s2 += rc4->state[++(rc4->__s1)]; 
        register unsigned char temp = rc4->state[rc4->__s1];
        rc4->state[rc4->__s1] = rc4->state[rc4->__s2];
        rc4->state[rc4->__s2] = temp; 

        temp=rc4->state[rc4->__s1] + rc4->state[rc4->__s2];
        msg[ci] ^= rc4->state[temp];
    }
}

void free_rc4(rc4_t * rc4)
{
    free(rc4);
}








#if WITH_TESTS
void
test()
{
    rc4_t* rp = init_rc4("hello",strlen("hello"));
    char*text="Bye"; 
    char * buffer1 = malloc(strlen(text));
    if(!buffer1){
        printf("Error in malloc");
        exit(-1);
    }

    strcpy(buffer1,text);
    int i;
    for(i=0;i<2;i++){
        printf ( "'%s' --> ",buffer1);
        transform_rc4(rp, buffer1,strlen(buffer1));
        printf ( "'%s'\n",buffer1);
    }
    free(buffer1);buffer1=0;
    free_rc4(rp);
}


int
main(int argc, char *argv[])
{

    test();
    printf("\n");
}
#endif