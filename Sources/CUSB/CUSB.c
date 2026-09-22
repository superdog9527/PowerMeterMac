#include "CUSB.h"
#include "libusb.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
struct pm_usb {
    libusb_context *context;
    libusb_device_handle *handle;
    uint16_t sequence;
    int voltage_confirmed;
    pthread_mutex_t control;
};
static int u16(const uint8_t *p) { return p[0] | p[1] << 8; }
const char *pm_error(int c) {
    switch(c) {
        case -100: return "安全保护：仅允许 600–5000 mV，禁止未确认电压时开启输出";
        case -101: return "设备应答无效、长度不符或命令被拒绝";
        case -102: return "检测到多台设备，请指定 USB 序列号";
        case -103: return "不支持的 USB 接口或端点";
        default: return libusb_error_name(c);
    }
}
int pm_validate_command(uint8_t op, const uint8_t *p, int n, int safe) {
    if(n<0 || (n && !p))return -100;
    switch(op) {
        case 2: case 0x0d: case 0x12: return n==0 ? 0:-100;
        case 3: return n==2 && u16(p)>=600 && u16(p)<=5000 ? 0:-100;
        case 5: return n==1 && p[0]==1 && safe ? 0:-100;
        case 6: case 8: return n==1 && p[0]==0 ? 0:-100;
        case 7: return n==1 && p[0]==1 ? 0:-100;
        case 0x10: return n==1 && p[0]==10 ? 0:-100;
        default: return -100;
    }
}
int pm_list(char *out, int cap) {
    libusb_context *ctx=NULL; libusb_device **list=NULL;
    int rc=libusb_init(&ctx); if(rc<0)return rc;
    ssize_t count=libusb_get_device_list(ctx,&list); int used=0, found=0;
    for(ssize_t i=0;i<count;i++) {
        struct libusb_device_descriptor d;
        if(libusb_get_device_descriptor(list[i],&d)<0 || d.idVendor!=0x0811 || d.idProduct!=0xf122)continue;
        unsigned char serial[128]={0};libusb_device_handle *h=NULL;
        if(libusb_open(list[i],&h)==0){libusb_get_string_descriptor_ascii(h,d.iSerialNumber,serial,sizeof(serial)-1);libusb_close(h);}
        // Serial descriptor is rendered as plain text, not interpreted as JSON.
        if(used<cap)used+=snprintf(out+used,cap-used,"%s\n",serial[0]?(char *)serial:"(无法读取序列号)");
        found++;
    }
    if(list)libusb_free_device_list(list,1);libusb_exit(ctx);return count<0?(int)count:found;
}
pm_usb *pm_open(const char *serial, char *error, int cap) {
    pm_usb *u=calloc(1,sizeof(*u)); if(!u)return NULL;
    int rc=libusb_init(&u->context); if(rc<0)goto fail;
    libusb_device **list=NULL;ssize_t count=libusb_get_device_list(u->context,&list);int matches=0;
    rc=LIBUSB_ERROR_NO_DEVICE;
    for(ssize_t i=0;i<count;i++) {
        struct libusb_device_descriptor d;
        if(libusb_get_device_descriptor(list[i],&d)<0 || d.idVendor!=0x0811 || d.idProduct!=0xf122)continue;
        libusb_device_handle *h=NULL;int r=libusb_open(list[i],&h);
        if(r<0){rc=r;continue;}
        unsigned char sn[128]={0};libusb_get_string_descriptor_ascii(h,d.iSerialNumber,sn,sizeof(sn)-1);
        if(serial && serial[0] && strcmp(serial,(char*)sn)){libusb_close(h);continue;}
        matches++; if(!u->handle)u->handle=h;else libusb_close(h);
    }
    if(list)libusb_free_device_list(list,1);
    if(matches>1){rc=-102;goto fail;} if(!u->handle)goto fail;
    // Locally observed recovery for an unresponsive endpoint. Allow the device
    // a full second to settle; a 250 ms delay was unreliable on reopening.
    rc=libusb_reset_device(u->handle); if(rc<0)goto fail;
    struct timespec settle={1,0}; nanosleep(&settle,NULL);
    struct libusb_config_descriptor *cfg=NULL;
    rc=libusb_get_active_config_descriptor(libusb_get_device(u->handle),&cfg);if(rc<0)goto fail;
    int mask=0;
    for(int i=0;i<cfg->bNumInterfaces;i++)for(int j=0;j<cfg->interface[i].num_altsetting;j++) {
        const struct libusb_interface_descriptor *it=&cfg->interface[i].altsetting[j];
        if(it->bInterfaceNumber || it->bAlternateSetting)continue;
        for(int k=0;k<it->bNumEndpoints;k++) {
            const struct libusb_endpoint_descriptor *ep=&it->endpoint[k];
            if(ep->bEndpointAddress==0x81 && (ep->bmAttributes&3)==2)mask|=1;
            if(ep->bEndpointAddress==0x02 && (ep->bmAttributes&3)==3)mask|=2;
            if(ep->bEndpointAddress==0x82 && (ep->bmAttributes&3)==3)mask|=4;
        }
    }
    libusb_free_config_descriptor(cfg); if(mask!=7){rc=-103;goto fail;}
    rc=libusb_claim_interface(u->handle,0);if(rc<0)goto fail;
    pthread_mutex_init(&u->control,NULL);u->sequence=1;return u;
fail:
    if(error && cap)snprintf(error,cap,"%s",pm_error(rc));
    if(u->handle)libusb_close(u->handle);if(u->context)libusb_exit(u->context);free(u);return NULL;
}
int pm_command(pm_usb *u, uint8_t op, const uint8_t *payload, int n, uint8_t *reply, int cap) {
    if(!u)return LIBUSB_ERROR_NO_DEVICE;
    pthread_mutex_lock(&u->control);
    int rc=pm_validate_command(op,payload,n,u->voltage_confirmed);if(rc<0)goto done;
    if(op==3)u->voltage_confirmed=0;
    uint16_t seq=u->sequence++;
    uint8_t request[14]={0xed,0xde,seq&255,seq>>8,1,op,0,0,0,0,(uint8_t)(12+n),0};
    if(n)memcpy(request+12,payload,n);
    int written=0;rc=libusb_interrupt_transfer(u->handle,2,request,12+n,&written,500);
    if(rc<0)goto done; if(written!=12+n){rc=-101;goto done;}
    // Skip stale responses; every accepted response must match the request sequence AND opcode.
    for(int attempt=0;attempt<8;attempt++) {
        uint8_t response[16384];int got=0;
        rc=libusb_interrupt_transfer(u->handle,0x82,response,sizeof(response),&got,300);
        if(rc<0)goto done;
        if(got<12 || response[0]!=0xed || response[1]!=0xde || u16(response+2)!=seq)continue;
        if(got<13 || response[4]!=1 || response[5]!=(op|0x80) || u16(response+10)!=got || response[12]!=0){rc=-101;goto done;}
        if(got>cap || !reply){rc=-101;goto done;}
        memcpy(reply,response,got);if(op==3)u->voltage_confirmed=1;rc=got;goto done;
    }
    rc=-101;
done: pthread_mutex_unlock(&u->control);return rc;
}
int pm_read(pm_usb *u,uint8_t *buf,int cap,int timeout) {
    if(!u)return LIBUSB_ERROR_NO_DEVICE;
    int n=0;int rc=libusb_bulk_transfer(u->handle,0x81,buf,cap,&n,timeout);
    if(rc==0 || (rc==LIBUSB_ERROR_TIMEOUT && n>0))return n;
    return rc==LIBUSB_ERROR_TIMEOUT ? 0:rc;
}
void pm_close(pm_usb *u) {
    if(!u)return;
    uint8_t p=0,reply[16384];
    pm_command(u,6,&p,1,reply,sizeof(reply));
    pm_command(u,8,&p,1,reply,sizeof(reply));
    libusb_release_interface(u->handle,0);libusb_close(u->handle);libusb_exit(u->context);
    pthread_mutex_destroy(&u->control);free(u);
}
