// Copyright (c) 2013, Facebook, Inc.
// All rights reserved.
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//   * Redistributions of source code must retain the above copyright notice,
//     this list of conditions and the following disclaimer.
//   * Redistributions in binary form must reproduce the above copyright notice,
//     this list of conditions and the following disclaimer in the documentation
//     and/or other materials provided with the distribution.
//   * Neither the name Facebook nor the names of its contributors may be used to
//     endorse or promote products derived from this software without specific
//     prior written permission.
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// Adapted for NotTheInstagram: image-scoped rebinding only. See README.md.
#include "fishhook.h"
#include <dlfcn.h>
#include <stdbool.h>
#include <string.h>
#include <mach/mach.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#ifdef __LP64__
typedef struct mach_header_64 mach_header_t;
typedef struct segment_command_64 segment_command_t;
typedef struct section_64 section_t;
typedef struct nlist_64 nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT_64
#else
typedef struct mach_header mach_header_t;
typedef struct segment_command segment_command_t;
typedef struct section section_t;
typedef struct nlist nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT
#endif

static int rebind_section(const struct rebinding bindings[], size_t count,
                          const section_t *section, intptr_t slide,
                          const nlist_t *symbols, const char *strings,
                          const uint32_t *indirect_symbols) {
  const uint32_t *indices = indirect_symbols + section->reserved1;
  void **slots = (void **)((uintptr_t)slide + section->addr);
  int status = 0;
  for (size_t i = 0; i < section->size / sizeof(void *); i++) {
    uint32_t index = indices[i];
    if (index == INDIRECT_SYMBOL_ABS || index == INDIRECT_SYMBOL_LOCAL ||
        index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
    const char *name = strings + symbols[index].n_un.n_strx;
    if (!name[0] || !name[1]) continue;
    for (size_t j = 0; j < count; j++) {
      if (strcmp(name + 1, bindings[j].name) != 0) continue;
      if (slots[i] == bindings[j].replacement) break;
      // Preserve upstream's iOS 15+ protection handling: never write if the
      // section cannot be made writable. Report failure to the caller.
      kern_return_t error = vm_protect(mach_task_self(), (vm_address_t)slots,
          section->size, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
      if (error == KERN_SUCCESS) slots[i] = bindings[j].replacement;
      else status = -1;
      break;
    }
  }
  return status;
}

int rebind_symbols_image(void *image, intptr_t slide,
                         const struct rebinding bindings[], size_t count) {
  const mach_header_t *header = image;
  Dl_info info;
  if (!dladdr(header, &info)) return 0;

  const segment_command_t *linkedit = NULL;
  const struct symtab_command *symtab = NULL;
  const struct dysymtab_command *dysymtab = NULL;
  uintptr_t command = (uintptr_t)header + sizeof(*header);
  for (uint32_t i = 0; i < header->ncmds; i++) {
    const struct load_command *load = (const void *)command;
    if (load->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
      const segment_command_t *segment = (const void *)command;
      if (strcmp(segment->segname, SEG_LINKEDIT) == 0) linkedit = segment;
    } else if (load->cmd == LC_SYMTAB) symtab = (const void *)command;
    else if (load->cmd == LC_DYSYMTAB) dysymtab = (const void *)command;
    command += load->cmdsize;
  }
  if (!linkedit || !symtab || !dysymtab || !dysymtab->nindirectsyms) return 0;

  uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
  const nlist_t *symbols = (const void *)(base + symtab->symoff);
  const char *strings = (const void *)(base + symtab->stroff);
  const uint32_t *indirect_symbols = (const void *)(base + dysymtab->indirectsymoff);
  command = (uintptr_t)header + sizeof(*header);
  int status = 0;
  for (uint32_t i = 0; i < header->ncmds; i++) {
    const struct load_command *load = (const void *)command;
    if (load->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
      const segment_command_t *segment = (const void *)command;
      if (strcmp(segment->segname, SEG_DATA) == 0 ||
          strcmp(segment->segname, "__DATA_CONST") == 0) {
        const section_t *sections = (const void *)(command + sizeof(*segment));
        for (uint32_t j = 0; j < segment->nsects; j++) {
          uint32_t type = sections[j].flags & SECTION_TYPE;
          if (type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS) {
            if (rebind_section(bindings, count, &sections[j], slide,
                               symbols, strings, indirect_symbols) != 0) status = -1;
          }
        }
      }
    }
    command += load->cmdsize;
  }
  return status;
}
