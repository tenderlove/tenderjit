# TenderJIT

TenderJIT is an experimental JIT compile for Ruby that is written in Ruby.
It's design is highly based off [YJIT](https://github.com/shopify/yjit).

## Using TenderJIT

Right now, TenderJIT doesn't automatically compile methods.  You must manually
tell TenderJIT to compile a method.

Lets look at an example:

```ruby
require "tenderjit"

def fib n
  if n < 3
    1
  else
    fib(n - 1) + fib(n - 2)
  end
end

jit = TenderJIT.new
jit.compile(method(:fib)) # Compile the `fib` method

# Run the `fib` method with the JIT enabled
jit.enable!
fib 8
jit.disable!
```

Eventually TenderJIT will compile code automatically, but today it doesn't.

## How does TenderJIT work?

TenderJIT reads each YARV instruction in the target method, then converts that
instruction to machine code.

Let's look at an example of this in action.  Say we have a function like this:

```ruby
def add a, b
  a + b
end
```

If we disassemble the method using `RubyVM::InstructionSequence`, we can see
the instructions that YARV uses to implement the add method:

```
$ cat x.rb
def add a, b
  a + b
end

$ ruby --dump=insns x.rb
== disasm: #<ISeq:<main>@x.rb:1 (1,0)-(3,3)> (catch: FALSE)
0000 definemethod                           :add, add                 (   1)[Li]
0003 putobject                              :add
0005 leave

== disasm: #<ISeq:add@x.rb:1 (1,0)-(3,3)> (catch: FALSE)
local table (size: 2, argc: 2 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
[ 2] a@0<Arg>   [ 1] b@1<Arg>
0000 getlocal_WC_0                          a@0                       (   2)[LiCa]
0002 getlocal_WC_0                          b@1
0004 opt_plus                               <calldata!mid:+, argc:1, ARGS_SIMPLE>[CcCr]
0006 leave                                                            (   3)[Re]
```

The `add` method calls 4 instructions, 3 of them are unique:

* `getlocal_WC_0`
* `opt_plus`
* `leave`

The YARV virtual machine works by pushing and popping values on a stack.  The
first two calls to `getlocal_WC_0` take one parameter, 0, and 1 respectively.
This means "get the local at index 0 and push it on the stack", and "get the
local at index 1 and push it on the stack".

After these two instructions have executed, the stack should have two values on
it.  The `opt_plus` instructions pops two values from the stack, adds them,
then pushes the summed value on the stack.  This leaves 1 value on the stack.

Finally the `leave` instruction pops one value from the stack and returns that
value to the calling method.

TenderJIT works by examining each of these instructions, then converts them to
machine code at runtime.  If a machine code version of the method is available
at run-time, then YARV will call the machine code version rather than the
YARV byte code version.

## Hacking on TenderJIT

The main compiler object is the `TenderJIT::ISEQCompiler` class which can be
found in [`lib/tenderjit/iseq_compiler.rb`](lib/tenderjit/iseq_compiler.rb).

Each instruction sequence object (method, block, etc) gets its own instance of
an `ISEQCompiler` object.

Each YARV instruction has a corresponding `handle_*` method in the
`ISEQCompiler` class.  The example above used `getlocal_WC_0`, `opt_plus`, and
`leave`.  Each of these instructions have corresponding `handle_getlocal_WC_0`,
`handle_opt_plus`, and `handle_leave` methods in the `ISEQCompiler` class.

When a request is made to compile an instruction sequence (iseq), the compiler
checks to see if there is already an ISEQCompiler object associated with the
iseq.  If not, it allocates one, then calls `compile` on the object.

The compiler will compile as many instructions in a row as it can, then will
quit compilation.  Depending on the instructions that were compiled, it may
resume later on.

Not all instructions have corresponding `handle_*` methods.  This just means
they are not implemented yet!  If you find an instruction you'd like to implement,
please do it!

When no corresponding handler function is found, the compiler will generate an
"exit" and the machine code will pass control back to YARV.  YARV will resume
where the compiler left off, so even partially compiled instruction sequences
will work.

YARV has a few data structures that you need to be aware of when hacking on
TenderJIT.  First is the "control frame pointer" or CFP.  The CFP represents
a stack frame.  Each time we call a method, an new stack frame is created.

The CFP points to the iseq it's executing.  It also points to the Program
Counter, or PC.  The PC indicates which instruction is going to execute next.
The other crucial thing the CFP points to is the Stack Pointer, or SP.  The SP
indicates where the *top* of the stack is, and it points at the "next empty slot"
in the stack.

When a function is called, a new CFP is created.  The CFP is initialized with
the first instruction in the iseq set as the PC, and an empty slot in the SP.
When `getlocal_WC_0` executes, first it advances the PC to point at the *next*
instruction.  Then `getlocal_WC_0` fetches the local value, writes it to the
empty SP slot, then pushes the SP slot up by one.

TenderJIT gains speed by eliminating PC and SP advancement.  This means that
as TenderJIT machine code executes, the values on the CFP may not reflect
reality!  In order to hand control back to YARV, TenderJIT must write accurate
values back to the CFP before returning control.

## Lazy compilation

TenderJIT is a lazy compiler.  It (very poorly) implements a version of [Lazy
Basic Block Versioning](https://arxiv.org/abs/1411.0352).  TenderJIT will only
compile one basic block at a time.  This means that TenderJIT will stop compiling
any time it finds an instruction that might jump somewhere else.

For example:

```ruby
def add a, b
  puts "hi"

  if a > 0
    b - a
  else
    a + b
  end
end
```

TenderJIT will compile the method calls as well as the comparison, but when it
sees there is a conditional, it will stop compiling.  At that point, it inserts
a "stub" which is just a way to resume compilation at that point.  These "stubs"
call back in to the compiler and ask it to resume compilation from that point.

Runtime compilation methods start with `compile_*` rather than `handle_*`.

As a practical example, lets look at how the compiler handles the following code:

```ruby
def get_a_const
  Foo
end
```

The instructions for this method are as follows:

```
== disasm: #<ISeq:get_a_const@x.rb:1 (1,0)-(3,3)> (catch: FALSE)
0000 opt_getinlinecache                     9, <is:0>                 (   2)[LiCa]
0003 putobject                              true
0005 getconstant                            :Foo
0007 opt_setinlinecache                     <is:0>
0009 leave                                                            (   3)[Re]
```

If we check [the implementation of `opt_getinlinecache` in YARV](https://github.com/ruby/ruby/blob/9770bf23b7a273246b9a6b084e79a8fb6fc1af11/insns.def#L1005-L1020), we see that it will check a cache.
If the cache is valid it will jump to the destination instruction, in this case
the instruction at position 9 (you can see that 9 is a parameter on the right of `opt_getinlinecache`).
Since this function can jump, we consider it the end of a basic block.
At compile time, TenderJIT doesn't know the machine address where it would have to jump.
So it inserts a "stub" which calls the method `compile_opt_getinlinecache`, but
*at runtime* rather than compile time.

The runtime function will examine the cache.  If the cache is valid, it patches
the calling jump instruction *in the generated machine code* to just jump to
the destination.

The next time the machine code is run, it no longer calls in to the lazy compile
method, but jumps directly where it needs to go.

## Why TenderJIT?

I built this JIT for several reasons.  The first, main reason, is that I'm helping
to build a more production ready actually-fast-and-good JIT at work called [YJIT](https://github.com/shopify/yjit).
I was not confident in my skills to build a JIT whatsoever, so I wanted to try
my hand at building one, but in pure Ruby.

The second reason is that I wanted to see if it was possible to write a JIT for
Ruby in pure Ruby (apparently it is).

My ultimate goal is to be able to ship a gem, and people can just require the gem
and their code is suddenly faster.

I picked the name "TenderJIT" because I thought it was silly.  If this project
can become a serious JIT contender then I'll probably consider renaming it to
something that sounds more serious like "SeriousJIT" or "AdequateCodeGenerator".

## How can I help?

If you'd like a low friction way to mess around with a JIT compiler, please
help contribute!

You can contribute by adding missing instructions or adding tests, or whatever
you want to do!

Lots of TenderJIT internals just look like x86-64 assembly, and I'd like to
get away from that.  So I've been working on a DSL to hide the assembly language
away from developers.  I need help developing that and converting the existing
"assembly-like" code to use the runtime class.

You can find the DSL in [`lib/tenderjit/runtime.rb`](lib/tenderjit/runtime.rb).

Thanks for reading!  If you want to help out, please ping me on Twitter or
open an issue!
