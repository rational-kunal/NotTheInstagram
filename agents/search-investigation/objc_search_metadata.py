import mmap,struct,json,re,sys
path=sys.argv[1]
f=open(path,'rb'); d=mmap.mmap(f.fileno(),0,access=mmap.ACCESS_READ)
u32=lambda o:struct.unpack_from('<I',d,o)[0]
u64=lambda o:struct.unpack_from('<Q',d,o)[0] & 0xfffffffff
i32=lambda o:struct.unpack_from('<i',d,o)[0]
segs=[];sects=[]; off=32
for i in range(u32(16)):
 cmd,size=struct.unpack_from('<II',d,off)
 if cmd==0x19:
  name=d[off+8:off+24].rstrip(b'\0').decode(); va,vs,fo,fs=struct.unpack_from('<QQQQ',d,off+24);segs.append((va,vs,fo,fs,name))
  for j in range(u32(off+64)):
   p=off+72+80*j; sn=d[p:p+16].rstrip(b'\0').decode();addr,sz=struct.unpack_from('<QQ',d,p+32);sects.append((sn,addr,sz,u32(p+48)))
 off+=size

def ofs(va):
 for a,vs,o,fs,n in segs:
  if a<=va<a+fs:return o+va-a
 raise ValueError(hex(va))
def ptr(va):return u64(ofs(va))
def st(va):
 o=ofs(va);end=d.find(b'\0',o);return d[o:end].decode(errors='replace')
def methods(va):
 if not va:return []
 o=ofs(va); flags,count=struct.unpack_from('<II',d,o);stride=flags&0xffff; relative=bool(flags&0x80000000); direct=bool(flags&0x40000000);out=[]
 for j in range(count):
  q=o+8+j*stride;v=va+8+j*stride
  if relative:
   name=v+i32(q); name=name if direct else ptr(name);types=v+4+i32(q+4); imp=v+8+i32(q+8)
  else:name,types,imp=[u64(q+8*k) for k in range(3)]
  out.append({'selector':st(name),'types':st(types),'imp':hex(imp)})
 return out

def klass(va,meta=False):
 o=ofs(va);isa,sup,cache,vtab,ro=[u64(o+8*k) for k in range(5)];ro&=~7;r=ofs(ro);name=st(u64(r+24));ml=u64(r+32)
 return {'class':name,'address':hex(va),'super_address':hex(sup),'methods':methods(ml),'class_methods':methods(u64(ofs(isa)+32) and u64(ofs(u64(ofs(isa)+32)&~7)+32)) if not meta else []}
# Avoid fragile metaclass indirection duplication; parse only implementation method list via direct helper.
def info(va):
 o=ofs(va);isa,sup,cache,vtab,ro=[u64(o+8*k) for k in range(5)];r=ofs(ro&~7);name=st(u64(r+24));methods_=methods(u64(r+32));out={'class':name,'address':hex(va),'super_address':hex(sup),'methods':methods_}
 try: mr=ofs(u64(ofs(isa)+32)&~7);out['class_methods']=methods(u64(mr+32))
 except Exception as e:out['class_methods_error']=str(e)
 return out
out=[]
for sn,va,sz,o in sects:
 if sn=='__objc_classlist':
  for p in range(o,o+sz,8):
   a=u64(p)
   try:
    r=ofs(u64(ofs(a)+32)&~7);n=st(u64(r+24))
    if re.search(r'(SearchResults|SearchAccounts|SearchNewTypeahead|SearchGenericTypeahead|SearchViewController|SearchTabContext|SearchSerp.*(Playback|SectionController)|SearchServerResultsStore|SearchResultSectionController)',n):out.append(info(a))
   except Exception:pass
json.dump({'path':path,'source':'original Mach-O Objective-C class_ro_t and method_list_t metadata; no target execution','classes':out},sys.stdout,indent=2)
