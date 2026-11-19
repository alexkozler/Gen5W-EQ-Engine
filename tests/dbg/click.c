#include "../../native/eqengine.c"
#include <stdio.h>
static const effect_uuid_t IMPL = { 0x64b3439e, 0x9662, 0x4040, 0x9fd1, { 0x83, 0xf1, 0x16, 0xf7, 0x49, 0x88 } };
static int32_t cmd(effect_handle_t h, uint32_t code, uint32_t size, void *data) { int32_t r; uint32_t rs = 4; (*h)->command(h, code, size, data, &rs, &r); return r; }
static void setp(effect_handle_t h, eqe_settings s) { char buf[sizeof(effect_param_t)+4+sizeof(s)]; effect_param_t *p=(effect_param_t*)buf; p->psize=4; p->vsize=sizeof(s); int32_t id=10; memcpy(p->data,&id,4); memcpy(p->data+4,&s,sizeof(s)); cmd(h, EFFECT_CMD_SET_PARAM, sizeof(buf), p); }
int main(int argc, char **argv) {
    int guard = argc > 1 ? atoi(argv[1]) : 1; double amp = argc > 2 ? atof(argv[2]) : 0.25; int gain = argc > 3 ? atoi(argv[3]) : 1200;
    enum { N = 2048 }; static int16_t mix[N*2]; effect_handle_t h; AELI.create_effect(&IMPL,0,2,&h);
    effect_config_t cfg; memset(&cfg,0,sizeof(cfg)); cfg.inputCfg.samplingRate=cfg.outputCfg.samplingRate=44100; cfg.inputCfg.channels=cfg.outputCfg.channels=3; cfg.inputCfg.format=cfg.outputCfg.format=1; cfg.inputCfg.buffer.frameCount=N; cfg.outputCfg.accessMode=0;
    cmd(h, EFFECT_CMD_SET_CONFIG, sizeof(cfg), &cfg); cmd(h, EFFECT_CMD_ENABLE, 0, NULL);
    eqe_settings s; memset(&s,0,sizeof(s)); s.layout=1; s.eq_on=1; s.guard_on=guard; setp(h,s);
    audio_buffer_t b = { N, { mix } }; double ph=0; int prev=0, n=0;
    for (int blk=0; blk<30; blk++) {
        if (blk==10) { s.band_cdb[5]=gain; setp(h,s); }
        for (int i=0;i<N;i++){ double v=amp*sin(ph); ph+=2*EQE_PI*1000/44100; mix[2*i]=mix[2*i+1]=(int16_t)floor(v*32767+0.5);} 
        (*h)->process(h,&b,&b);
        int mx=0, ms=0, at=0; for(int i=0;i<N;i++){int st=abs(mix[2*i]-prev); prev=mix[2*i]; if(st>ms){ms=st;at=i;} if(abs(mix[2*i])>mx) mx=abs(mix[2*i]);}
        if (blk>=8 && blk<16) printf("blk %d: peak %d, max step %d at %d, g2 %.4f\n", blk, mx, ms, at, ((eqe_ctx*)h)->g2);
        n++;
    }
    return 0;
}
