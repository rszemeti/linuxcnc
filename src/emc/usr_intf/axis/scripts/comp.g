#!/usr/bin/python
#    This is 'comp', a tool to write HAL boilerplate
#    Copyright 2006 Jeff Epler <jepler@unpythonic.net>
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the Free Software
#    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

import os, sys, tempfile, shutil, getopt, time

%%
parser Hal:
    ignore: "//.*"
    ignore: "/[*](.|\n)*?[*]/"
    ignore: "[ \t\r\n]+"

    token END: ";;"
    token PARAMDIRECTION: "rw|r"
    token PINDIRECTION: "in|out|io"
    token TYPE: "float|bit|u32|s32|u16|s16|u8|s8"
    token NAME: "[a-zA-Z_][a-zA-Z0-9_]*"
    token FPNUMBER: "([0-9]*\.[0-9]+|[0-9]+\.)([Ee][+-]?[0-9]+)?f?"
    token NUMBER: "[0-9]+|0x[0-9a-fA-F]+"
    token STRING: '"(\\.|[^"])*"'

    rule File: Declaration* "$" {{ return True }}
    rule Declaration:
        "component" NAME OptString";" {{ comp(NAME, OptString); }}
      | "pin" NAME TYPE PINDIRECTION OptString ";"  {{ pin(NAME, TYPE, PINDIRECTION, OptString) }}
      | "param" NAME TYPE PARAMDIRECTION OptString OptAssign ";" {{ param(NAME, TYPE, PARAMDIRECTION, OptString, OptAssign) }}
      | "function" NAME OptFP OptString ";"       {{ function(NAME, OptFP, OptString) }}
      | "option" NAME OptValue ";"   {{ option(NAME, OptValue) }}

    rule OptString: STRING {{ return eval(STRING) }} | {{ return '' }}
    rule OptAssign: "=" Value {{ return Value; }}
                | {{ return None }}
    rule OptFP: "fp" {{ return 1 }} | "nofp" {{ return 0 }} | {{ return 1 }}
    rule Value: "yes" {{ return 1 }} | "no" {{ return 0 }}  
                | "true" {{ return 1 }} | "false" {{ return 0 }}  
                | NAME {{ return NAME }}
                | FPNUMBER {{ return float(FPNUMBER.rstrip("f")) }}
                | NUMBER {{ return int(NUMBER,0) }}
    rule OptValue: Value {{ return Value }}
                | {{ return 1 }}
%%

def parse(rule, text, filename=None):
    P = Hal(HalScanner(text, filename=filename))
    return runtime.wrap_error_reporter(P, rule)

dirmap = {'r': 'HAL_RO', 'rw': 'HAL_RW', 'in': 'HAL_IN', 'out': 'HAL_OUT', 'io': 'HAL_IO' }

def initialize():
    global functions, params, pins, options, comp_name, names, docs

    functions = []; params = []; pins = []; options = {}
    docs = []
    comp_name = None

    names = {}

def comp(name, doc):
    docs.append(('component', name, doc))
    global comp_name
    if comp_name:
        raise runtime.SyntaxError, "Duplicate specification of component name"
    comp_name = name;

def pin(name, type, dir, doc):
    if name in names:
        raise runtime.SyntaxError, "Duplicate item name %s" % name
    docs.append(('pin', name, type, dir, doc))
    names[name] = None
    pins.append((name, type, dir))

def param(name, type, dir, doc, value):
    if name in names:
        raise runtime.SyntaxError, "Duplicate item name %s" % name
    docs.append(('param', name, type, dir, doc, value))
    names[name] = None
    params.append((name, type, dir, value))

def function(name, fp, doc):
    if name in names:
        raise runtime.SyntaxError, "Duplicate item name %s" % name
    docs.append(('funct', name, fp, doc))
    names[name] = None
    functions.append((name, fp))

def option(name, value):
    if name in options:
        raise runtime.SyntaxError, "Duplicate option name %s" % name
    options[name] = value

def removeprefix(s,p):
    if s.startswith(p): return s[len(p):]
    return s

def to_hal(name):
    return name.replace("_", "-").rstrip("-").rstrip(".")

def prologue(f):
    print >> f, "/* Autogenerated by %s on %s -- do not edit */" % (
        sys.argv[0], time.asctime())
    print >> f, """\
#include "rtapi.h"
#include "rtapi_app.h"
#include "hal.h"

static int comp_id;
"""
    names = {}

    def q(s):
        s = s.replace("\\", "\\\\")
        s = s.replace("\r", "\\r")
        s = s.replace("\n", "\\n")
        s = s.replace("\t", "\\t")
        s = s.replace("\v", "\\v")
        return '"%s"' % s

    print >>f, "#ifdef MODULE_INFO"
    for v in docs:
        if not v: continue
        v = ":".join(map(str, v))
        print >>f, "MODULE_INFO(emc2, %s);" % q(v)
    print >>f, "#endif // __MODULE_INFO"
    print >>f

    has_data = options.get("data")

    print >>f
    print >>f, "struct state {"
    for name, type, dir in pins:
        if names.has_key(name):
            raise RuntimeError, "Duplicate item name: %s" % name
        print >>f, "    hal_%s_t *%s;" % (type, name)
        names[name] = 1

    for name, type, dir, value in params:
        if names.has_key(name):
            raise RuntimeError, "Duplicate item name: %s" % name
        print >>f, "    hal_%s_t %s;" % (type, name)
        names[name] = 1

    if has_data:
        print >>f, "    void *_data;"

    print >>f, "};"
    
    print >>f
    for name, fp in functions:
        if names.has_key(name):
            raise RuntimeError, "Duplicate item name: %s" % name
        print >>f, "static void %s(struct state *inst, long period);" % name
        names[name] = 1

    print >>f, "static int get_data_size(void);"
    if options.get("extra_setup"):
        print >>f, "static int extra_setup(struct state *inst, long extra_arg);"
    if options.get("extra_cleanup"):
        print >>f, "static void extra_cleanup(void);"

    print >>f
    print >>f, "static int export(char *prefix, long extra_arg) {"
    print >>f, "    char buf[HAL_NAME_LEN + 2];"
    print >>f, "    int r = 0;"
    print >>f, "    int sz = sizeof(struct state) + get_data_size();"
    print >>f, "    struct state *inst = hal_malloc(sz);"
    print >>f, "    memset(inst, 0, sz);"
    if options.get("extra_setup"):
	print >>f, "    r = extra_setup(inst, extra_arg);"
	print >>f, "    if(r != 0) return r;"

    for name, type, dir in pins:
        print >>f, "    r = hal_pin_%s_newf(%s, &(inst->%s), comp_id," % (
            type, dirmap[dir], name)
        print >>f, "        \"%%s%s\", prefix);" % to_hal("." + name)
        print >>f, "    if(r != 0) return r;"

    for name, type, dir, value in params:
        print >>f, "    r = hal_param_%s_newf(%s, &(inst->%s), comp_id," % (
            type, dirmap[dir], name)
        print >>f, "        \"%%s%s\", prefix);" % to_hal("." + name)
        if value is not None:
            print >>f, "    inst->%s = %s;" % (name, value)
        print >>f, "    if(r != 0) return r;"

    for name, fp in functions:
        print >>f, "    rtapi_snprintf(buf, HAL_NAME_LEN, \"%%s%s\", prefix);"\
            % to_hal("." + name)
        print >>f, "    r = hal_export_funct(buf, (void(*)(void *inst, long))%s, inst, %s, 0, comp_id);" % (
            name, int(fp))
        print >>f, "    if(r != 0) return r;"
    print >>f, "    return 0;"
    print >>f, "}"

    if options.get("count_function"):
        print >>f, "static int get_count(void);"

    if options.get("rtapi_app", 1):
        if not options.get("singleton") and not options.get("count_function") :
            print >>f, "static int count = %s;" \
                % options.get("default_count", 1)
            print >>f, "MODULE_PARM(count, \"i\");"
            print >>f, "MODULE_PARM_DESC(count, \"number of %s\");" % comp_name

        print >>f, "int rtapi_app_main(void) {"
        print >>f, "    int r = 0;"
        if not options.get("singleton"):
            print >>f, "    int i;"
        if options.get("count_function"):
            print >>f, "    int count = get_count();"
        print >>f, "    comp_id = hal_init(\"%s\");" % comp_name
        print >>f, "    if(comp_id < 0) return comp_id;"

        if options.get("singleton"):
            print >>f, "    r = export(\"%s\", 0);" % \
                    to_hal(removeprefix(comp_name, "hal_"))
        else:
            print >>f, "    for(i=0; i<count; i++) {"
            print >>f, "        char buf[HAL_NAME_LEN + 2];"
            print >>f, "        rtapi_snprintf(buf, HAL_NAME_LEN, " \
                                        "\"%s.%%d\", i);" % \
                    to_hal(removeprefix(comp_name, "hal_"))
            print >>f, "        r = export(buf, i);"
            print >>f, "        if(r != 0) break;"
            print >>f, "    }"
        print >>f, "    if(r) {"
	if options.get("extra_cleanup"):
            print >>f, "    extra_cleanup();"
        print >>f, "        hal_exit(comp_id);"
        print >>f, "    }"
        print >>f, "    return r;";
        print >>f, "}"

        print >>f
        print >>f, "void rtapi_app_exit(void) {"
	if options.get("extra_cleanup"):
            print >>f, "    extra_cleanup();"
        print >>f, "    hal_exit(comp_id);"
        print >>f, "}"

    print >>f
    if not options.get("no_convenience_defines"):
        print >>f, "#define FUNCTION(name) static void name(struct state *inst, long period)"
        print >>f, "#define EXTRA_SETUP() static int extra_setup(struct state *inst, long extra_arg)"
        print >>f, "#define EXTRA_CLEANUP() static void extra_cleanup(void)"
        print >>f, "#define fperiod (period * 1e-9)"
        for name, type, dir in pins:
            if dir == 'in':
                print >>f, "#define %s (0+*inst->%s)" % (name, name)
            else:
                print >>f, "#define %s (*inst->%s)" % (name, name)
        for name, type, dir, value in params:
            print >>f, "#define %s (inst->%s)" % (name, name)
        
        if has_data:
            print >>f, "#define data (*(%s*)&(inst->_data))" % options['data']
    print >>f
    print >>f

def epilogue(f):
    data = options.get('data')
    print >>f
    if data:
        print >>f, "static int get_data_size(void) { return sizeof(%s); }" % data
    else:
        print >>f, "static int get_data_size(void) { return 0; }"

INSTALL, COMPILE, PREPROCESS, DOCUMENT = range(4)

modinc = None
def find_modinc():
    global modinc
    if modinc: return modinc
    d = os.path.abspath(os.path.dirname(os.path.dirname(sys.argv[0])))
    for e in ['src', 'etc/emc2', '/etc/emc2']:
        e = os.path.join(d, e, 'Makefile.modinc')
        if os.path.exists(e):
            modinc = e
            return e
    raise SystemExit, "Unable to locate Makefile.modinc"

def build(tempdir, filename, mode):
    kobjname = os.path.splitext(filename)[0] + ".ko"
    objname = os.path.basename(os.path.splitext(filename)[0] + ".o")
    makefile = os.path.join(tempdir, "Makefile")
    f = open(makefile, "w")
    print >>f, "include %s" % find_modinc()
    print >>f, "obj-m += %s" % objname
    f.close()
    if mode == INSTALL:
        target = "modules install"
    else:
        target = "modules"
    result = os.system("cd %s; make -S %s" % (tempdir, target))
    if result != 0:
        raise SystemExit, result
    if mode == COMPILE:
        shutil.copy(kobjname, os.path.basename(kobjname))

def finddoc(section=None, name=None):
    for item in docs:
        if ((section == None or section == item[0]) and
                (name == None or name == item[1])): return item
    return None

def finddocs(section=None, name=None):
    for item in docs:
        if ((section == None or section == item[0]) and
                (name == None or name == item[1])):
                    yield item

def to_hal_man(s):
    if options.get("singleton"):
        s = "%s.%s" % (comp_name, s)
    else:
        s = "%s.\\fIN\\fB.%s" % (comp_name, s)
    s = s.replace("_", "-")
    s = s.rstrip("-")
    s = s.rstrip(".")
    s = s.replace("-", "\\-")
    return s

def document(filename, outfilename):
    if outfilename is None:
        outfilename = os.path.splitext(filename)[0] + ".9"

    initialize()
    f = open(filename).read()
    a, b = f.split("\n;;\n", 1)

    p = parse('File', a, filename)
    if not p: raise SystemExit, 1

    f = open(outfilename, "w")

    print >>f, ".TH %s \"9\" \"%s\" \"EMC Documentation\" \"HAL Component\"" % (
        comp_name.upper(), time.strftime("%F"))

    print >>f, ".SH NAME\n"
    doc = finddoc('component')    
    if doc and doc[2]:
        print >>f, "%s \\- %s" % (doc[1], doc[2])
    else:
        print >>f, "%s" % doc[1]


    print >>f, ".SH SYNOPSIS"
    if options.get("singleton"):
        print >>f, ".B loadrt %s ..." % comp_name
    else:
        print >>f, ".B loadrt %s [count=\\fIN\\fB] ..." % comp_name

    print >>f, ".SH FUNCTIONS"
    for _, name, fp, doc in finddocs('funct'):
        print >>f, ".TP"
        print >>f, "\\fB%s\\fR" % to_hal_man(name),
        if fp:
            print >>f, "(uses floating-point)"
        else:
            print >>f
        print >>f, doc

    print >>f, ".SH PINS"
    for _, name, type, dir, doc in finddocs('pin'):
        print >>f, ".TP"
        print >>f, "\\fB%s\\fR" % to_hal_man(name),
        print >>f, type, dir
        print >>f, doc
    print >>f, ".SH PARAMETERS"
    for _, name, type, dir, doc, value in finddocs('param'):
        print >>f, ".TP"
        print >>f, "\\fB%s" % to_hal_man(name),
        print >>f, type, dir,
        if value:
            print >>f, "\\fR(default: \\fI%s\\fF)" % value
        else:
            print >>f, "\\fR"
        print >>f, doc

def process(filename, mode, outfilename):
    tempdir = tempfile.mkdtemp()
    try:
        if outfilename is None:
            if mode == PREPROCESS:
                outfilename = os.path.splitext(filename)[0] + ".c"
            else:
                outfilename = os.path.join(tempdir,
                    os.path.splitext(os.path.basename(filename))[0] + ".c")

        initialize()

        f = open(filename).read()
        a, b = f.split("\n;;\n", 1)

        p = parse('File', a, filename)
        if not p: raise SystemExit, 1

        f = open(outfilename, "w")

        prologue(f)
        lineno = a.count("\n") + 3
        f.write("#line %d \"%s\"\n" % (lineno, filename))
        f.write(b)
        epilogue(f)
        f.close()

        if mode != PREPROCESS:
            build(tempdir, outfilename, mode)

    finally:
        shutil.rmtree(tempdir) 

def main():
    mode = PREPROCESS
    outfile = None
    opts, args = getopt.getopt(sys.argv[1:], "icpdo:",
                       ['install', 'compile', 'preprocess', 'outfile=',
                        'document'])

    for k, v in opts:
        if k in ("-i", "--install"):
            mode = INSTALL
        if k in ("-c", "--compile"):
            mode = COMPILE
        if k in ("-p", "--preprocess"):
            mode = PREPROCESS
        if k in ("-d", "--document"):
            mode = DOCUMENT
        if k in ("-o", "--outfile"):
            if len(args) != 1:
                raise SystemExit, "Cannot specify -o with multiple input files"
            outfile = v 
    if outfile and mode != PREPROCESS and mode != DOCUMENT:
        raise SystemExit, "Can only specify -o when preprocessing or documenting"

    for f in args:
        if f.endswith(".comp") and mode == DOCUMENT:
            document(f, outfile)            
        elif f.endswith(".comp"):
            process(f, mode, outfile)
        elif f.endswith(".c") and mode != PREPROCESS:
            tempdir = tempfile.mkdtemp()
            try:
                shutil.copy(f, tempdir)
                build(tempdir, os.path.join(tempdir, os.path.basename(f)), mode)
            finally:
                shutil.rmtree(tempdir) 
        else:
            raise SystemExit, "Unrecognized file type: %s" % f

if __name__ == '__main__':
    main()

# vim:sw=4:sts=4:et
