// Copyright (c) Facebook, Inc. and its affiliates.
//
// This source code is licensed under the MIT license found in the
// LICENSE file in the root directory of this source tree.
//
// fishhook implementation

#include "fishhook.h"

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/vm_region.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>

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

#ifndef SEG_DATA_CONST
#define SEG_DATA_CONST "__DATA_CONST"
#endif

struct rebindings_entry {
  struct rebinding *rebindings;
  size_t rebindings_nel;
  struct rebindings_entry *next;
};

static struct rebindings_entry *_rebindings_head;

static int prepend_rebindings(struct rebindings_entry **rebindings_head,
                              struct rebinding rebindings[], size_t nel) {
  struct rebindings_entry *new_entry =
      (struct rebindings_entry *)malloc(sizeof(struct rebindings_entry));
  if (!new_entry) {
    return -1;
  }
  new_entry->rebindings =
      (struct rebinding *)malloc(sizeof(struct rebinding) * nel);
  if (!new_entry->rebindings) {
    free(new_entry);
    return -1;
  }
  memcpy(new_entry->rebindings, rebindings, sizeof(struct rebinding) * nel);
  new_entry->rebindings_nel = nel;
  new_entry->next = *rebindings_head;
  *rebindings_head = new_entry;
  return 0;
}

static vm_prot_t get_protection(void *sectionStart) {
  mach_port_t task = mach_task_self();
  vm_size_t size = 0;
  vm_address_t address = (vm_address_t)sectionStart;
  memory_object_name_t object;
#if __LP64__
  mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
  vm_region_basic_info_data_64_t info;
  kern_return_t info_ret =
      vm_region_64(task, &address, &size, VM_REGION_BASIC_INFO_64,
                   (vm_region_info_64_t)&info, &count, &object);
#else
  mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT;
  vm_region_basic_info_data_t info;
  kern_return_t info_ret =
      vm_region(task, &address, &size, VM_REGION_BASIC_INFO,
                (vm_region_info_t)&info, &count, &object);
#endif
  if (info_ret == KERN_SUCCESS) {
    return info.protection;
  } else {
    return VM_PROT_READ;
  }
}

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#else
typedef void *id;
extern void NSLog(id format, ...);
extern id stringWithUTF8String(const char *);
#endif

static bool is_memory_readable(void *address, size_t size) {
  vm_address_t addr = (vm_address_t)address;
  vm_size_t vmsize = 0;
  mach_port_t task = mach_task_self();

#if __LP64__
  mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
  vm_region_basic_info_data_64_t info;
  memory_object_name_t object;
  kern_return_t ret =
      vm_region_64(task, &addr, &vmsize, VM_REGION_BASIC_INFO_64,
                   (vm_region_info_64_t)&info, &count, &object);
#else
  mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT;
  vm_region_basic_info_data_t info;
  memory_object_name_t object;
  kern_return_t ret = vm_region(task, &addr, &vmsize, VM_REGION_BASIC_INFO,
                                (vm_region_info_t)&info, &count, &object);
#endif

  if (ret != KERN_SUCCESS)
    return false;
  // Check if our range is covered
  if (addr > (vm_address_t)address)
    return false; // Starts after
  if ((addr + vmsize) < ((vm_address_t)address + size))
    return false; // Ends before
  return true;
}

static void perform_rebinding_with_section(struct rebindings_entry *rebindings,
                                           section_t *section, intptr_t slide,
                                           nlist_t *symtab, char *strtab,
                                           uint32_t *indirect_symtab,
                                           uint32_t symtab_count,
                                           uint32_t strtab_size,
                                           uint32_t indirect_symtab_count) {
  if (!section || section->size == 0) {
    return;
  }

  // NSLog(@"[fishhook] Processing section: %.16s", section->sectname);

  const bool isDataConst = strcmp(section->segname, SEG_DATA_CONST) == 0;
  uint32_t *indirect_symbol_indices = indirect_symtab + section->reserved1;
  void **indirect_symbol_bindings = (void **)((uintptr_t)slide + section->addr);

  // Safety check: validate indirect_symbol_bindings is accessible
  if (!indirect_symbol_bindings) {
    return;
  }

  // Check if memory is readable
  if (!is_memory_readable(indirect_symbol_bindings, section->size)) {
    // NSLog(@"[fishhook] Warning: Section %.16s (addr %p) is not
    // readable/mapped. Skipping.", section->sectname,
    // indirect_symbol_bindings);
    return;
  }

  vm_prot_t oldProtection = VM_PROT_READ;
  if (isDataConst) {
    oldProtection = get_protection(indirect_symbol_bindings);
    int res = mprotect(indirect_symbol_bindings, section->size,
                       PROT_READ | PROT_WRITE);
    if (res != 0) {
      // NSLog(@"[fishhook] Error: mprotect failed for section %.16s",
      // section->sectname);
      return;
    }
  }

  for (uint i = 0; i < section->size / sizeof(void *); i++) {
    // Safety check: validate indirect symbol table index
    if (section->reserved1 + i >= indirect_symtab_count) {
      continue;
    }

    uint32_t symtab_index = indirect_symbol_indices[i];
    if (symtab_index == INDIRECT_SYMBOL_ABS ||
        symtab_index == INDIRECT_SYMBOL_LOCAL ||
        symtab_index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
      continue;
    }
    // Safety check: validate symtab_index is within bounds
    if (symtab_index >= symtab_count) {
      continue;
    }
    uint32_t strtab_offset = symtab[symtab_index].n_un.n_strx;
    // Safety check: validate strtab_offset is within bounds
    if (strtab_offset >= strtab_size) {
      continue;
    }
    char *symbol_name = strtab + strtab_offset;
    // Safety check: ensure we can read at least 2 bytes for the check below
    // and that the string is within bounds.
    // We check [1] so we need offset + 1 < size.
    if (strtab_offset + 1 >= strtab_size) {
      continue;
    }

    bool symbol_name_longer_than_1 = symbol_name[0] && symbol_name[1];
    struct rebindings_entry *cur = rebindings;
    while (cur) {
      for (uint j = 0; j < cur->rebindings_nel; j++) {
        if (symbol_name_longer_than_1 &&
            strcmp(&symbol_name[1], cur->rebindings[j].name) == 0) {

          if (cur->rebindings[j].replaced != NULL &&
              indirect_symbol_bindings[i] != cur->rebindings[j].replacement) {
            *(cur->rebindings[j].replaced) = indirect_symbol_bindings[i];
          }

          // Use direct assignment if mprotect succeeded
          indirect_symbol_bindings[i] = cur->rebindings[j].replacement;

          goto symbol_loop;
        }
      }
      cur = cur->next;
    }
  symbol_loop:;
  }

  if (isDataConst) {
    int protection = 0;
    if (oldProtection & VM_PROT_READ) {
      protection |= PROT_READ;
    }
    if (oldProtection & VM_PROT_WRITE) {
      protection |= PROT_WRITE;
    }
    if (oldProtection & VM_PROT_EXECUTE) {
      protection |= PROT_EXEC;
    }
    mprotect(indirect_symbol_bindings, section->size, protection);
  }
}

static void rebind_symbols_for_image(struct rebindings_entry *rebindings,
                                     const struct mach_header *header,
                                     intptr_t slide) {
  Dl_info info;
  if (dladdr(header, &info) == 0) {
    return;
  }

  // NSLog(@"[fishhook] Image: %s", info.dli_fname);

  segment_command_t *cur_seg_cmd;
  segment_command_t *linkedit_segment = NULL;
  struct symtab_command *symtab_cmd = NULL;
  struct dysymtab_command *dysymtab_cmd = NULL;

  uintptr_t cur = (uintptr_t)header + sizeof(mach_header_t);
  for (uint i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
    cur_seg_cmd = (segment_command_t *)cur;
    if (cur_seg_cmd->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
      if (strcmp(cur_seg_cmd->segname, SEG_LINKEDIT) == 0) {
        linkedit_segment = cur_seg_cmd;
      }
    } else if (cur_seg_cmd->cmd == LC_SYMTAB) {
      symtab_cmd = (struct symtab_command *)cur_seg_cmd;
    } else if (cur_seg_cmd->cmd == LC_DYSYMTAB) {
      dysymtab_cmd = (struct dysymtab_command *)cur_seg_cmd;
    }
  }

  if (!symtab_cmd || !dysymtab_cmd || !linkedit_segment) {
    return;
  }

  uintptr_t linkedit_base =
      (uintptr_t)slide + linkedit_segment->vmaddr - linkedit_segment->fileoff;

  // Verify linkedit_base within reason?

  nlist_t *symtab = (nlist_t *)(linkedit_base + symtab_cmd->symoff);
  char *strtab = (char *)(linkedit_base + symtab_cmd->stroff);
  uint32_t *indirect_symtab =
      (uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);

  cur = (uintptr_t)header + sizeof(mach_header_t);
  for (uint i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
    cur_seg_cmd = (segment_command_t *)cur;
    if (cur_seg_cmd->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
      if (strcmp(cur_seg_cmd->segname, SEG_DATA) != 0 &&
          strcmp(cur_seg_cmd->segname, SEG_DATA_CONST) != 0) {
        continue;
      }
      for (uint j = 0; j < cur_seg_cmd->nsects; j++) {
        section_t *sect = (section_t *)(cur + sizeof(segment_command_t)) + j;
        if ((sect->flags & SECTION_TYPE) == S_LAZY_SYMBOL_POINTERS) {
          perform_rebinding_with_section(rebindings, sect, slide, symtab,
                                         strtab, indirect_symtab,
                                         symtab_cmd->nsyms, symtab_cmd->strsize,
                                         dysymtab_cmd->nindirectsyms);
        }
        if ((sect->flags & SECTION_TYPE) == S_NON_LAZY_SYMBOL_POINTERS) {
          perform_rebinding_with_section(rebindings, sect, slide, symtab,
                                         strtab, indirect_symtab,
                                         symtab_cmd->nsyms, symtab_cmd->strsize,
                                         dysymtab_cmd->nindirectsyms);
        }
      }
    }
  }
}

static void _rebind_symbols_for_image(const struct mach_header *header,
                                      intptr_t slide) {
  rebind_symbols_for_image(_rebindings_head, header, slide);
}

int rebind_symbols_image(void *header, intptr_t slide,
                         struct rebinding rebindings[], size_t rebindings_nel) {
  struct rebindings_entry *rebindings_head = NULL;
  int retval = prepend_rebindings(&rebindings_head, rebindings, rebindings_nel);
  rebind_symbols_for_image(rebindings_head, (const struct mach_header *)header,
                           slide);
  if (rebindings_head) {
    free(rebindings_head->rebindings);
  }
  free(rebindings_head);
  return retval;
}

int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel) {
  int retval =
      prepend_rebindings(&_rebindings_head, rebindings, rebindings_nel);
  if (retval < 0) {
    return retval;
  }
  if (!_rebindings_head->next) {
    _dyld_register_func_for_add_image(_rebind_symbols_for_image);
  } else {
    uint32_t c = _dyld_image_count();
    for (uint32_t i = 0; i < c; i++) {
      _rebind_symbols_for_image(_dyld_get_image_header(i),
                                _dyld_get_image_vmaddr_slide(i));
    }
  }
  return retval;
}
