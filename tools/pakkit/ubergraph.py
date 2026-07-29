"""Engine-accurate Kismet offset computation + pseudocode renderer over wandsmith tojson output.

UE jump offsets use MEMORY accounting: pointers = 8 bytes, FName = 12 bytes, opcode = 1.
Validated by asserting every Jump/JumpIfNot/PushExecutionFlow target lands on a statement start.

Usage: python ubergraph.py <char.json> <ExportIndex|Name> [startOffset endOffset]
"""
import json, sys

PTR = 8
NAME = 12


def T(e):
    return e.get("$type", "").split(".")[-1].split(",")[0] if isinstance(e, dict) else ""


def size(e):
    """Memory-accounting serialized size of one expression."""
    t = T(e)
    if t in ("EX_LocalVariable", "EX_InstanceVariable", "EX_DefaultVariable",
             "EX_LocalOutVariable", "EX_ClassSparseDataVariable", "EX_PropertyConst"):
        return 1 + PTR
    if t in ("EX_Self", "EX_IntZero", "EX_IntOne", "EX_True", "EX_False", "EX_NoObject",
             "EX_NoInterface", "EX_Nothing", "EX_EndOfScript", "EX_PopExecutionFlow",
             "EX_DeprecatedOp4A", "EX_WireTracepoint", "EX_Tracepoint", "EX_Breakpoint"):
        return 1
    if t == "EX_IntConst":
        return 1 + 4
    if t in ("EX_ByteConst", "EX_IntConstByte"):
        return 1 + 1
    if t in ("EX_Int64Const", "EX_UInt64Const", "EX_DoubleConst"):
        return 1 + 8
    if t == "EX_FloatConst":
        return 1 + 4
    if t == "EX_BitFieldConst":
        return 1 + PTR + 1
    if t == "EX_StringConst":
        return 1 + len(e.get("Value") or "") + 1
    if t == "EX_UnicodeStringConst":
        return 1 + 2 * (len(e.get("Value") or "") + 1)
    if t == "EX_NameConst":
        return 1 + NAME
    if t == "EX_ObjectConst":
        return 1 + PTR
    if t in ("EX_SoftObjectConst", "EX_FieldPathConst"):
        return 1 + size(e.get("Value"))
    if t == "EX_VectorConst":
        return 1 + 24
    if t == "EX_Vector3fConst":
        return 1 + 12
    if t == "EX_RotationConst":
        return 1 + 24
    if t == "EX_TransformConst":
        return 1 + 80
    if t in ("EX_LocalFinalFunction", "EX_FinalFunction", "EX_CallMath"):
        return 1 + PTR + sum(size(p) for p in e.get("Parameters") or []) + 1
    if t == "EX_CallMulticastDelegate":
        return (1 + PTR + size(e.get("Delegate"))
                + sum(size(p) for p in e.get("Parameters") or []) + 1)
    if t in ("EX_LocalVirtualFunction", "EX_VirtualFunction"):
        return 1 + NAME + sum(size(p) for p in e.get("Parameters") or []) + 1
    if t in ("EX_Context", "EX_Context_FailSilent", "EX_ClassContext"):
        return (1 + size(e.get("ObjectExpression")) + 4 + PTR
                + size(e.get("ContextExpression")))
    if t == "EX_InterfaceContext":
        return 1 + size(e.get("InterfaceValue"))
    if t == "EX_BitFieldConst":
        return 1 + PTR + 1
    if t == "EX_Let":
        return 1 + PTR + size(e.get("Variable")) + size(e.get("Expression"))
    if t in ("EX_LetObj", "EX_LetWeakObjPtr", "EX_LetBool", "EX_LetDelegate",
             "EX_LetMulticastDelegate"):
        return 1 + size(e.get("VariableExpression")) + size(e.get("AssignmentExpression"))
    if t == "EX_LetValueOnPersistentFrame":
        return 1 + PTR + size(e.get("AssignmentExpression"))
    if t == "EX_StructMemberContext":
        return 1 + PTR + size(e.get("StructExpression"))
    if t == "EX_Jump":
        return 1 + 4
    if t == "EX_JumpIfNot":
        return 1 + 4 + size(e.get("BooleanExpression"))
    if t == "EX_ComputedJump":
        return 1 + size(e.get("CodeOffsetExpression"))
    if t == "EX_PushExecutionFlow":
        return 1 + 4
    if t == "EX_PopExecutionFlowIfNot":
        return 1 + size(e.get("BooleanExpression"))
    if t == "EX_Return":
        return 1 + size(e.get("ReturnExpression"))
    if t == "EX_SkipOffsetConst":
        return 1 + 4
    if t == "EX_Skip":
        return 1 + 4 + size(e.get("SkipExpression"))
    if t == "EX_Assert":
        return 1 + 2 + 1 + size(e.get("AssertExpression"))
    if t == "EX_StructConst":
        return 1 + PTR + 4 + sum(size(v) for v in e.get("Value") or []) + 1
    if t == "EX_SetArray":
        ap = e.get("AssigningProperty")
        return (1 + (size(ap) if ap is not None else PTR)
                + sum(size(v) for v in e.get("Elements") or []) + 1)
    if t == "EX_ArrayConst":
        return 1 + PTR + 4 + sum(size(v) for v in e.get("Elements") or []) + 1
    if t == "EX_SetConst":
        return 1 + PTR + 4 + sum(size(v) for v in e.get("Elements") or []) + 1
    if t == "EX_MapConst":
        return 1 + PTR + PTR + 4 + sum(size(v) for v in e.get("Elements") or []) + 1
    if t == "EX_SetSet":
        return (1 + size(e.get("SetProperty")) + 4
                + sum(size(v) for v in e.get("Elements") or []) + 1)
    if t == "EX_SetMap":
        return (1 + size(e.get("MapProperty")) + 4
                + sum(size(v) for v in e.get("Elements") or []) + 1)
    if t == "EX_SwitchValue":
        s = 1 + 2 + 4 + size(e.get("IndexTerm"))
        for c in e.get("Cases") or []:
            s += size(c.get("CaseIndexValueTerm")) + 4 + size(c.get("CaseTerm"))
        return s + size(e.get("DefaultTerm"))
    if t == "EX_ArrayGetByRef":
        return 1 + size(e.get("ArrayVariable")) + size(e.get("ArrayIndex"))
    if t in ("EX_DynamicCast", "EX_ObjToInterfaceCast", "EX_CrossInterfaceCast",
             "EX_InterfaceToObjCast", "EX_MetaCast"):
        return 1 + PTR + size(e.get("Target"))
    if t == "EX_PrimitiveCast":
        return 1 + 1 + size(e.get("Target"))
    if t == "EX_Cast":
        return 1 + 1 + size(e.get("Target"))
    if t == "EX_InstanceDelegate":
        return 1 + NAME
    if t == "EX_BindDelegate":
        return 1 + NAME + size(e.get("Delegate")) + size(e.get("ObjectTerm"))
    if t in ("EX_AddMulticastDelegate", "EX_RemoveMulticastDelegate"):
        return 1 + size(e.get("Delegate")) + size(e.get("DelegateToAdd"))
    if t == "EX_Assert":
        return 1 + 2 + 1 + size(e.get("AssertExpression"))
    if t == "EX_ClearMulticastDelegate":
        return 1 + size(e.get("DelegateToClear"))
    if t == "EX_TextConst":
        v = e.get("Value") or {}
        tt = str(v.get("TextLiteralType", ""))
        s = 1 + 1
        if tt in ("Empty",):
            return s
        if tt == "LocalizedText":
            return (s + size(v.get("LocalizedSource")) + size(v.get("LocalizedKey"))
                    + size(v.get("LocalizedNamespace")))
        if tt == "InvariantText":
            return s + size(v.get("InvariantLiteralString"))
        if tt == "LiteralString":
            return s + size(v.get("LiteralString"))
        if tt == "StringTableEntry":
            return (s + PTR + size(v.get("StringTableId")) + size(v.get("StringTableKey")))
        raise SystemExit(f"unknown text literal type {tt}")
    raise SystemExit(f"no size rule for {t}: {json.dumps(e)[:200]}")


def pname(v):
    if isinstance(v, dict):
        new = v.get("New") or {}
        path = new.get("Path") or []
        if path:
            return str(path[-1])
    return "?"


def fname(v):
    """StackNode is a package index: negative = import, positive = export."""
    return resolve(v)


def render(e):
    if e is None:
        return "null"
    t = T(e)
    if t in ("EX_LocalVariable", "EX_InstanceVariable", "EX_DefaultVariable",
             "EX_LocalOutVariable", "EX_ClassSparseDataVariable"):
        return pname(e.get("Variable"))
    if t == "EX_Self":
        return "self"
    if t == "EX_True":
        return "true"
    if t == "EX_False":
        return "false"
    if t == "EX_IntZero":
        return "0"
    if t == "EX_IntOne":
        return "1"
    if t in ("EX_IntConst", "EX_Int64Const", "EX_UInt64Const", "EX_FloatConst",
             "EX_DoubleConst", "EX_ByteConst", "EX_IntConstByte", "EX_SkipOffsetConst",
             "EX_BitFieldConst"):
        return str(e.get("Value"))
    if t in ("EX_StringConst", "EX_UnicodeStringConst", "EX_NameConst"):
        return repr(str(e.get("Value")))
    if t == "EX_ObjectConst":
        return "Obj(" + resolve(e.get("Value")) + ")"
    if t in ("EX_NoObject", "EX_NoInterface"):
        return "None"
    if t in ("EX_VectorConst", "EX_Vector3fConst", "EX_RotationConst", "EX_TransformConst"):
        return t[3:] + str(e.get("Value"))
    if t in ("EX_SoftObjectConst", "EX_FieldPathConst"):
        return t[3:] + "(" + render(e.get("Value")) + ")"
    if t in ("EX_LocalFinalFunction", "EX_FinalFunction", "EX_CallMath"):
        params = ", ".join(render(p) for p in e.get("Parameters") or [])
        return f"{fname(e.get('StackNode'))}({params})"
    if t == "EX_CallMulticastDelegate":
        params = ", ".join(render(p) for p in e.get("Parameters") or [])
        return f"multicast {render(e.get('Delegate'))}({params})"
    if t in ("EX_LocalVirtualFunction", "EX_VirtualFunction"):
        params = ", ".join(render(p) for p in e.get("Parameters") or [])
        return f"virtual {e.get('VirtualFunctionName')}({params})"
    if t in ("EX_Context", "EX_Context_FailSilent", "EX_ClassContext"):
        return render(e.get("ObjectExpression")) + "." + render(e.get("ContextExpression"))
    if t == "EX_InterfaceContext":
        return render(e.get("InterfaceValue"))
    if t == "EX_Let":
        return render(e.get("Variable")) + " = " + render(e.get("Expression"))
    if t in ("EX_LetObj", "EX_LetWeakObjPtr", "EX_LetBool", "EX_LetDelegate",
             "EX_LetMulticastDelegate"):
        return render(e.get("VariableExpression")) + " = " + render(e.get("AssignmentExpression"))
    if t == "EX_LetValueOnPersistentFrame":
        return pname(e.get("DestinationProperty")) + " = " + render(e.get("AssignmentExpression"))
    if t == "EX_StructMemberContext":
        return render(e.get("StructExpression")) + "." + pname(e.get("StructMemberExpression"))
    if t == "EX_Jump":
        return f"goto {e.get('CodeOffset')}"
    if t == "EX_JumpIfNot":
        return f"if not ({render(e.get('BooleanExpression'))}) goto {e.get('CodeOffset')}"
    if t == "EX_ComputedJump":
        return f"goto computed({render(e.get('CodeOffsetExpression'))})"
    if t == "EX_PushExecutionFlow":
        return f"pushflow {e.get('PushingAddress')}"
    if t == "EX_PopExecutionFlow":
        return "popflow"
    if t == "EX_PopExecutionFlowIfNot":
        return f"popflow if not ({render(e.get('BooleanExpression'))})"
    if t == "EX_Return":
        return "return " + render(e.get("ReturnExpression"))
    if t == "EX_Nothing":
        return "nop"
    if t == "EX_EndOfScript":
        return "end"
    if t == "EX_Skip":
        return render(e.get("SkipExpression"))
    if t == "EX_StructConst":
        return "struct(" + ", ".join(render(v) for v in e.get("Value") or []) + ")"
    if t == "EX_SetArray":
        return ("setarray " + render(e.get("AssigningProperty")) + " = ["
                + ", ".join(render(v) for v in e.get("Elements") or []) + "]")
    if t in ("EX_ArrayConst", "EX_SetConst", "EX_MapConst"):
        return t[3:] + "[" + ", ".join(render(v) for v in e.get("Elements") or []) + "]"
    if t in ("EX_SetSet", "EX_SetMap"):
        return t[3:] + "(...)"
    if t == "EX_SwitchValue":
        s = "switch(" + render(e.get("IndexTerm")) + "){"
        for c in e.get("Cases") or []:
            s += f" [{render(c.get('CaseIndexValueTerm'))} => {render(c.get('CaseTerm'))}]"
        return s + " default: " + render(e.get("DefaultTerm")) + "}"
    if t == "EX_ArrayGetByRef":
        return render(e.get("ArrayVariable")) + "[" + render(e.get("ArrayIndex")) + "]"
    if t in ("EX_DynamicCast", "EX_ObjToInterfaceCast", "EX_CrossInterfaceCast",
             "EX_InterfaceToObjCast", "EX_MetaCast"):
        return f"cast<{resolve(e.get('ClassPtr'))}>({render(e.get('Target'))})"
    if t in ("EX_PrimitiveCast", "EX_Cast"):
        return f"cast({render(e.get('Target'))})"
    if t == "EX_TextConst":
        v = e.get("Value") or {}
        return "text(" + render(v.get("LocalizedSource") or v.get("InvariantLiteralString")
                                 or v.get("LiteralString")) + ")"
    if t == "EX_InstanceDelegate":
        return "delegate " + str(e.get("FunctionName"))
    if t == "EX_BindDelegate":
        return (f"bind {e.get('FunctionName')} to {render(e.get('Delegate'))} on "
                + render(e.get("ObjectTerm")))
    if t in ("EX_AddMulticastDelegate", "EX_RemoveMulticastDelegate"):
        return f"{t[3:]}({render(e.get('Delegate'))}, {render(e.get('DelegateToAdd'))})"
    if t == "EX_ClearMulticastDelegate":
        return f"{t[3:]}({render(e.get('DelegateToClear'))})"
    if t in ("EX_WireTracepoint", "EX_Tracepoint", "EX_Breakpoint"):
        return "--"
    return t + "{?}"


IMPORTS, EXPORTS = [], []

def resolve(idx):
    try:
        i = int(idx)
    except (TypeError, ValueError):
        return str(idx)
    if i < 0 and -i - 1 < len(IMPORTS):
        return str(IMPORTS[-i - 1])
    if i > 0 and i - 1 < len(EXPORTS):
        return str(EXPORTS[i - 1])
    return str(idx)


def load(path, which):
    d = json.load(open(path, encoding="utf-8"))
    global IMPORTS, EXPORTS
    IMPORTS = [imp.get("ObjectName") for imp in d.get("Imports") or []]
    EXPORTS = [ex.get("ObjectName") for ex in d.get("Exports") or []]
    ex = d["Exports"]
    if which.isdigit():
        fe = ex[int(which)]
    else:
        fe = next(e for e in ex if str(e.get("ObjectName")) == which)
    return d, fe


def offsets(bc):
    offs, o = [], 0
    for ins in bc:
        offs.append(o)
        o += size(ins)
    return offs


def main():
    path, which = sys.argv[1], sys.argv[2]
    lo = int(sys.argv[3]) if len(sys.argv) > 3 else None
    hi = int(sys.argv[4]) if len(sys.argv) > 4 else None
    d, fe = load(path, which)
    bc = fe.get("ScriptBytecode") or []
    offs = offsets(bc)
    starts = set(offs)

    # validation: every jump target must be a statement start
    targets = []

    def walk(e):
        if isinstance(e, dict):
            t = T(e)
            if t in ("EX_Jump", "EX_JumpIfNot"):
                targets.append(e.get("CodeOffset"))
            elif t == "EX_PushExecutionFlow":
                targets.append(e.get("PushingAddress"))
            for v in e.values():
                walk(v)
        elif isinstance(e, list):
            for v in e:
                walk(v)

    for ins in bc:
        walk(ins)
    bad = [t for t in targets if t not in starts]
    print(f"# {fe['ObjectName']}: {len(bc)} statements, {len(targets)} jump targets, "
          f"{len(bad)} MISALIGNED{' <-- OFFSETS WRONG' if bad else ' (offsets exact)'}",
          file=sys.stderr)
    if bad:
        print("# bad sample:", sorted(set(bad))[:10], file=sys.stderr)

    for o, ins in zip(offs, bc):
        if lo is not None and (o < lo or o > hi):
            continue
        txt = render(ins)
        if txt == "--":
            continue
        print(f"[{o:>6}] {txt}")


if __name__ == "__main__":
    main()
