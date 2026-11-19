#include "../../native/eqengine.c"
#include <stdio.h>
static const effect_uuid_t IMPL = { 0x64b3439e, 0x9662, 0x4040, 0x9fd1, { 0x83, 0xf1, 0x16, 0xf7, 0x49, 0x88 } };
static int32_t cmd(effect_handle_t h, uint32_t code, uint32_t size, void *data) { int32_t r; uint32_t rs = 4; (*h)->command(h, code, size, data, &rs, &r); return r; }
static void setp(effect_handle_t h, eqe_settings s) { char buf[sizeof(effect_param_t)+4+sizeof(s)]; effect_param_t *p=(effect_param_t*)buf; p->psize=4; p->vsize=sizeof(s); int32_t id=10; memcpy(p->data,&id,4); memcpy(p->data+4,&s,sizeof(s)); cmd(h, EFFECT_CMD_SET_PARAM, sizeof(buf), p); }
int main(void) {
    enum { N = 2048 }; static int16_t mix[N*2]; effect_handle_t h; AELI.create_effect(&IMPL,0,2,&h);
    effect_config_t cfg; memset(&cfg,0,sizeof(cfg)); cfg.inputCfg.samplingRate=cfg.outputCfg.samplingRate=44100; cfg.inputCfg.channels=cfg.outputCfg.channels=3; cfg.inputCfg.format=cfg.outputCfg.format=1; cfg.inputCfg.buffer.frameCount=N;
    cmd(h, EFFECT_CMD_SET_CONFIG, sizeof(cfg), &cfg); cmd(h, EFFECT_CMD_ENABLE, 0, NULL);
    eqe_settings s; memset(&s,0,sizeof(s)); s.layout=1; s.eq_on=0; s.guard_on=1; s.preamp_cdb=-600; for(int i=0;i<10;i++) s.band_cdb[i]=(i%3)*400-400; setp(h,s);
    audio_buffer_t b = { N, { mix } }; double ph=0; int prev=0; int worst_toggle=0, worst_steady=0;
    for (int blk=0; blk<80; blk++) {
        int toggled = 0;
        if (blk>4 && blk%8==0) { s.eq_on = !s.eq_on; setp(h,s); toggled=1; }
        for (int i=0;i<N;i++){ double v=0.4*sin(ph)+0.2*sin(ph*3.7); ph+=2*EQE_PI*300/44100; mix[2*i]=mix[2*i+1]=(int16_t)floor(v*32767+0.5);} 
        (*h)->process(h,&b,&b);
        int ms=0; for(int i=0;i<N;i++){int st=abs(mix[2*i]-prev); prev=mix[2*i]; if(st>ms) ms=st;}
        if (blk>4) { if (toggled) { if (ms>worst_toggle) worst_toggle=ms; } else if (ms>worst_steady) worst_steady=ms; }
    }
    printf("EQ on/off toggles (10x) on a two-tone signal: largest step while toggling %d, steady %d, processing path now %d\n", worst_toggle, worst_steady, ((eqe_ctx*)h)->processing);
    AELI.release_effect(h);
    return 0;
}
