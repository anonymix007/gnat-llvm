------------------------------------------------------------------------------
--                              C C G                                       --
--                                                                          --
--                     Copyright (C) 2020-2022, AdaCore                     --
--                                                                          --
-- This is free software;  you can redistribute it  and/or modify it  under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

with Ada.Containers.Hashed_Maps;

with Einfo.Utils; use Einfo.Utils;
with Set_Targ;    use Set_Targ;
with Sinfo.Nodes; use Sinfo.Nodes;
with Table;

with GNATLLVM.Utils; use GNATLLVM.Utils;

with CCG.Environment; use CCG.Environment;

package body CCG.Utils is

   --  We have common code to scan a GEP. Return a record giving our result
   --  and then the external functions just extract the needed result
   --  from that.

   type VF is record
      V_Is_Volatile : Boolean;
      V_Is_Unsigned : Boolean;
   end record;

   function GEP_Volatile_And_Unsigned (V : Value_T) return VF
     with Pre => Is_A_Instruction (V);

   function Is_Unsigned_Ref (V : Value_T) return Boolean
     with Pre => Present (V);
   --  True if V is a reference to an unsigned integer, meaning that the
   --  result of a "load" instruction with that operand will produce
   --  an unsigned result.

   --  We have cases where we want to record information about components
   --  of LLVM types or values, such as fields of a struct type and
   --  parameters of a subprogram. We have a generic that allows us to
   --  record this for both types and values.

   generic
      type Key_T is private;
      No_Key_T : Key_T;
      with function Hash (K : Key_T) return Hash_Type;
      with function Should_Insert (K : Key_T) return Boolean;

   package Component_Info_P is

      type Component_Info_Idx is new Nat;
      No_Component_Info_Idx : constant Component_Info_Idx := 0;

      function Present (C : Component_Info_Idx) return Boolean is
        (C /= No_Component_Info_Idx);

      function Present (K : Key_T) return Boolean is (K /= No_Key_T);
      function No      (K : Key_T) return Boolean is (K = No_Key_T);

      procedure Set_Component_Info
        (UID         : Unique_Id;
         Idx         : Nat;
         Name        : Name_Id   := No_Name;
         Entity      : Entity_Id := Empty;
         Is_Padding  : Boolean   := False;
         Is_Bitfield : Boolean   := False);
      --  Set component info corresponding to Idx in the value or type to be
      --  denoted by UID.

      procedure Set_Key (UID : Unique_Id; K : Key_T)
        with Pre => Present (K);
      --  Indicate that UID corresponds to K

      function Get_Component_Name (K : Key_T; Idx : Nat) return Str
        with Pre => Present (K);
      --  Get the name previously stored for index Idx in key K

      function Get_Component_Entity (K : Key_T; Idx : Nat) return Entity_Id;
      --  Get the Entity previously stored for index Idx in key K

      function Is_Component_Padding (K : Key_T; Idx : Nat) return Boolean;
      --  Say whether the field at index Idx in key K is a padding field

   end Component_Info_P;

   package body Component_Info_P is

      type Component_Data is record
         K           : Key_T;
         --  LLVM type or value containing this component

         C_Number    : Nat;
         --  0-origin count of component in key

         Name        : Name_Id;
         --  If Present, the name of the component

         Entity      : Entity_Id;
         --  If Present, the GNAT entity for the component

         UID         : Unique_Id;
         --  A Unique_Id for the component; used only when initializing info

         Next        : Component_Info_Idx;
         --  Index of next field entry for this key

         Is_Padding  : Boolean;
         --  True if this componment is a field, is padding, and doesn't
         --  correspond to any source-level field.

         Is_Bitfield : Boolean;
         --  True if this is a field that's used to store one or more
         --  bitfields.

      end record;

      --  Define the table that records all of the component info

      package Component_Info is new Table.Table
        (Table_Component_Type => Component_Data,
         Table_Index_Type     => Component_Info_Idx,
         Table_Low_Bound      => 1,
         Table_Initial        => 500,
         Table_Increment      => 100,
         Table_Name           => "Component_Info");

      --  We need two maps into the above table. One maps a Unique_Id into
      --  a table entry. This is used to track the initial setting and is
      --  used again when we set the key.  The second maps a (key,
      --  component index) pair into the name info for that component.

      function Hash (UID : Unique_Id) return Hash_Type is (Hash_Type (UID));

      package Entity_To_CI_Maps is new Ada.Containers.Hashed_Maps
        (Key_Type        => Unique_Id,
         Element_Type    => Component_Info_Idx,
         Hash            => Hash,
         Equivalent_Keys => "=");
      Entity_To_CI_Map : Entity_To_CI_Maps.Map;

      type FC_Key is record
         K   : Key_T;
         Idx : Nat;
      end record;

      function Hash (K : FC_Key) return Hash_Type is
        (Hash (K.K) + Hash_Type (K.Idx));

      package CI_Maps is new Ada.Containers.Hashed_Maps
        (Key_Type        => FC_Key,
            Element_Type    => Component_Info_Idx,
         Hash            => Hash,
         Equivalent_Keys => "=");
      CI_Map : CI_Maps.Map;

      ------------------------
      -- Set_Component_Info --
      ------------------------

      procedure Set_Component_Info
        (UID         : Unique_Id;
         Idx         : Nat;
         Name        : Name_Id   := No_Name;
         Entity      : Entity_Id := Empty;
         Is_Padding  : Boolean   := False;
         Is_Bitfield : Boolean   := False)
      is
         use Entity_To_CI_Maps;
         Position : constant Cursor             :=
           Find (Entity_To_CI_Map, UID);
         C_Idx    : constant Component_Info_Idx :=
           (if   Has_Element (Position) then Element (Position)
            else No_Component_Info_Idx);

      begin
         --  Start by adding an entry to our table. Then either update the
         --  head of the chain or set a new head.

         Component_Info.Append ((K           => No_Key_T,
                                 C_Number    => Idx,
                                 Name        => Name,
                                 Entity      => Entity,
                                 UID         => UID,
                                 Next        => C_Idx,
                                 Is_Padding  => Is_Padding,
                                 Is_Bitfield => Is_Bitfield));
         if Has_Element (Position) then
            Replace_Element (Entity_To_CI_Map, Position,
                             Component_Info.Last);
         else
            Insert (Entity_To_CI_Map, UID, Component_Info.Last);
         end if;

      end Set_Component_Info;

      ----------------
      -- Set_Key --
      ----------------

      procedure Set_Key (UID : Unique_Id; K : Key_T) is
         package ECM renames Entity_To_CI_Maps;
         package TCM renames CI_Maps;
         Position : constant ECM.Cursor := ECM.Find (Entity_To_CI_Map, UID);
         C_Idx    : Component_Info_Idx;

      begin
         --  If we didn't make any entry in the table for this key, we
         --  don't have anything to do. This could have happened either if
         --  we weren't generating C or if UID denotes a null record or
         --  a subprogram with no parameters

         if not ECM.Has_Element (Position) then
            return;
         end if;

         --  Otherwise get the first entry we made and loop over all
         --  entries for UID, looking for entries where the key hasn't yet
         --  been set. For each, set the key and add the (key, field index)
         --  pair to the hash table, but if the type has no name, don't
         --  insert it into the table since it'll be a shared struct.

         C_Idx := ECM.Element (Position);
         while Present (C_Idx) loop
            declare
               CD : Component_Data renames Component_Info.Table (C_Idx);
            begin
               if No (CD.K) then
                  CD.K := K;

                  if Should_Insert (K) then
                     TCM.Insert (CI_Map, (K, CD.C_Number), C_Idx);
                  end if;
               end if;

               C_Idx := CD.Next;
            end;
         end loop;
      end Set_Key;

      ------------------------
      -- Get_Component_Name --
      ------------------------

      function Get_Component_Name (K : Key_T; Idx : Nat) return Str is
         use CI_Maps;
         Position : constant Cursor := Find (CI_Map, (K, Idx));
         CD       : Component_Data    :=
           (K, Idx, No_Name, Types.Empty, No_Unique_Id, No_Component_Info_Idx,
            False, False);

      begin
         --  If we have information for this field in our table (we should),
         --  replace the default above with that information.

         if Has_Element (Position) then
            CD := Component_Info.Table (Element (Position));
         end if;

         --  Now create a name for the component, based on the saved
         --  information.  We really shouldn't be requesting a padding
         --  field, but handle it anyway.

         if Present (CD.Name) then
            return Get_Name_String (CD.Name) + C_Name;
         elsif Present (CD.Entity) then
            return Get_Ext_Name (CD.Entity) + C_Name;
         elsif CD.Is_Padding then
            return "ccg_pad_" & Idx;
         elsif CD.Is_Bitfield then
            return "ccg_bits_" & Idx;
         else
            return "ccg_field_" & Idx;
         end if;
      end Get_Component_Name;

      --------------------------
      -- Get_Component_Entity --
      --------------------------

      function Get_Component_Entity (K : Key_T; Idx : Nat) return Entity_Id is
         use CI_Maps;
         Position : constant Cursor := Find (CI_Map, (K, Idx));

      begin
         return (if   Has_Element (Position)
                 then Component_Info.Table (Element (Position)).Entity
                 else Types.Empty);
      end Get_Component_Entity;

      --------------------------
      -- Is_Component_Padding --
      --------------------------

      function Is_Component_Padding (K : Key_T; Idx : Nat) return Boolean is
         use CI_Maps;
         Position : constant Cursor := Find (CI_Map, (K, Idx));

      begin
         return Has_Element (Position)
           and then Component_Info.Table (Element (Position)).Is_Padding;
      end Is_Component_Padding;

   end Component_Info_P;

   --  Now set up instantiations of the package for types and values

   function Should_Insert (Unused_T : Type_T) return Boolean renames Has_Name;
   function Should_Insert (Unused_V : Value_T) return Boolean is (True);

   package CI_T is new Component_Info_P  (Key_T         => Type_T,
                                          No_Key_T      => No_Type_T,
                                          Hash          => Hash,
                                          Should_Insert => Should_Insert);
   package CI_V is new Component_Info_P  (Key_T         => Value_T,
                                          No_Key_T      => No_Value_T,
                                          Hash          => Hash,
                                          Should_Insert => Should_Insert);

   --  And now use them to define the needed functions

   procedure Set_Field_C_Info
     (UID         : Unique_Id;
      Idx         : Nat;
      Name        : Name_Id   := No_Name;
      Entity      : Entity_Id := Empty;
      Is_Padding  : Boolean   := False;
      Is_Bitfield : Boolean   := False) renames CI_T.Set_Component_Info;

   procedure Set_Struct (UID : Unique_Id; T : Type_T) renames CI_T.Set_Key;
   function Get_Field_Name (T : Type_T; Idx : Nat) return Str
     renames CI_T.Get_Component_Name;
   function Get_Field_Entity (T : Type_T; Idx : Nat) return Entity_Id
     renames CI_T.Get_Component_Entity;
   function Is_Field_Padding (T : Type_T; Idx : Nat) return Boolean
     renames CI_T.Is_Component_Padding;

   procedure Set_Function (UID : Unique_Id; V : Value_T) renames CI_V.Set_Key;
   function Get_Parameter_Entity (V : Value_T; Idx : Nat) return Entity_Id
     renames CI_V.Get_Component_Entity;

   -------------------
   -- Set_Parameter --
   -------------------

   procedure Set_Parameter (UID : Unique_Id; Idx : Nat; Entity : Entity_Id) is
   begin
      CI_V.Set_Component_Info (UID, Idx, Entity => Entity);
   end Set_Parameter;

   ------------------------
   -- Is_Ref_To_Volatile --
   ------------------------

   function Is_Ref_To_Volatile (Op : Value_T) return Boolean is
   begin
      --  If it is volatile, then it's a reference to a volatile object

      if Is_Volatile (Op) then
         return True;

      --  If it's not an instruction, it's not a reference to volatile

      elsif not Is_A_Instruction (Op) then
         return False;
      end if;

      --  Otherwise, look at the opcode

      case Get_Opcode (Op) is

         --  For addition and subtraction look at the first operand

         when Op_Add | Op_Sub =>
            return Is_Ref_To_Volatile (Get_Operand0 (Op));

         --  For GEP, first look at the first operand

         when Op_Get_Element_Ptr =>
            return Is_Volatile_GEP (Op);

         --  All else isn't known to be volatile

         when others =>
            null;

      end case;

      return False;
   end Is_Ref_To_Volatile;

   ----------------------------
   -- GEP_Volatile_And_Field --
   ----------------------------

   function GEP_Volatile_And_Unsigned (V : Value_T) return VF is
      Aggr          : constant Value_T := Get_Operand0 (V);
      N_Ops         : constant Nat     := Get_Num_Operands (V);
      Aggr_T        : Type_T           := Get_Element_Type (Aggr);
      V_Is_Volatile : Boolean          := False;
      V_Is_Unsigned : Boolean          := False;

   begin
      --  If the input to GEP is volatile, its a reference to volatile

      if Is_Ref_To_Volatile (Aggr) then
         V_Is_Volatile := True;
      end if;

      --  Now look at all operands and find the relevant type for each.
      --  If its a struct, see if we know that the type is volatile.
      --  Otherwise, look at the field and its signedness/volatile
      --  status. We mark the result as volatile if any operand is and
      --  the signedness comes just from the last operand.

      for J in 2 .. N_Ops - 1 loop
         if Get_Type_Kind (Aggr_T) = Array_Type_Kind then
            Aggr_T        := Get_Element_Type (Aggr_T);
            V_Is_Unsigned := False;
         else
            pragma Assert (Get_Type_Kind (Aggr_T) = Struct_Type_Kind);

            declare
               Idx   : constant Nat                      :=
                 Nat (Const_Int_Get_S_Ext_Value (Get_Operand (V, J)));
               F     : constant Opt_Record_Field_Kind_Id :=
                 Get_Field_Entity (Aggr_T, Idx);

            begin
               if Present (F) then
                  V_Is_Unsigned :=
                    Is_Unsigned_Type (Full_Base_Type (Full_Etype (F)));
                  V_Is_Volatile :=
                    V_Is_Volatile or Treat_As_Volatile (F)
                    or Treat_As_Volatile (Full_Etype (F));
               end if;

               Aggr_T := Struct_Get_Type_At_Index (Aggr_T, Idx);
            end;
         end if;
      end loop;

      return (V_Is_Volatile, V_Is_Unsigned);
   end GEP_Volatile_And_Unsigned;

   ---------------------
   -- Is_Volatile_GEP --
   ---------------------

   function Is_Volatile_GEP (V : Value_T) return Boolean is
     (GEP_Volatile_And_Unsigned (V).V_Is_Volatile);

   ---------------------
   -- Is_Unsigned_GEP --
   ---------------------

   function Is_Unsigned_GEP (V : Value_T) return Boolean is
     (GEP_Volatile_And_Unsigned (V).V_Is_Unsigned);

   --------
   -- TP --
   --------

   function TP
     (S           : String;
      Op1         : Value_T := No_Value_T;
      Op2         : Value_T := No_Value_T;
      Op3         : Value_T := No_Value_T) return Str
   is
      Start     : Integer   := S'First;
      Result    : Str       := No_Str;
      Mark_Seen : Boolean   := False;
      Modifier  : Character := ' ';
      Op        : Value_T;
      Last      : Integer;

   begin
      for J in S'Range loop

         --  If we've seen '#', look for a modifier

         if Mark_Seen then
            if S (J) in 'A' | 'B' | 'D' | 'I' | 'L' | 'P' | 'T' then
               Modifier := S (J);

            --  If not, then this is a number, representing which operand
            --  to output, possibly as modified by a modifier.

            else
               Op := (case S (J) is when '1' => Op1, when '2' => Op2,
                                    when others => Op3);

               --  The end of any string to output is before our mark, which
               --  may be, e.g., #1 or #B2.

               Last := J - 2 - (if Modifier = ' ' then 0 else 1);
               if Start <= Last then
                  Result := Result & S (Start .. Last);
               end if;

               --  Output the (possibly modified) operand

               case Modifier is
                  when 'A' =>
                     Result := Result & Addr_Of (Op);
                  when 'B' =>
                     Result := Result & Value_As_Basic_Block (Op);
                  when 'D' =>
                     Result := Result & Deref (Op);
                  when 'I' =>
                     Result := Result & (Op + Initializer);
                  when 'L' =>
                     Result := Result & (Op + LHS);
                  when 'T' =>
                     Result := Result & (Op + Write_Type);
                  when others =>
                        Result := Result & Op;
               end case;

               --  Reset for the next string and/or mark

               Mark_Seen := False;
               Modifier  := ' ';
               Start     := J + 1;
            end if;

         elsif S (J) = '#' then
            Mark_Seen := True;
         end if;
      end loop;

      --  See if we have a final string to output and output it if so

      if Start <= S'Last then
         Result := Result & S (Start .. S'Last);
      end if;

      return Result;
   end TP;

   --------------
   -- Num_Uses --
   --------------

   function Num_Uses (V : Value_T) return Nat is
      V_Use : Use_T := Get_First_Use (V);

   begin
      return J : Nat := 0 do
         while Present (V_Use) loop
            J := J + 1;
            V_Use := Get_Next_Use (V_Use);
         end loop;
      end return;
   end Num_Uses;

   ---------------
   -- GNAT_Type --
   ---------------

   function GNAT_Type (V : Value_T) return Opt_Type_Kind_Id is
      E : constant Entity_Id := Get_Entity (V);

   begin
      return (if   No (E) then Types.Empty elsif Is_Type (E) then E
              else Full_Etype (E));
   end GNAT_Type;

   ---------------------
   -- Is_Unsigned_Ref --
   ---------------------

   function Is_Unsigned_Ref (V : Value_T) return Boolean is
      TE : constant Opt_Type_Kind_Id := GNAT_Type (V);
      BT : constant Opt_Type_Kind_Id := Opt_Full_Base_Type (TE);

   begin
      --  Note that what we care about here is whether the C compiler
      --  will interpret our generated code for V as a pointer to
      --  unsigned, not whether it actually IS unsigned. The only two
      --  cases where we have a pointer to unsigned are when we have the
      --  address of an unsigned variable or an unsigned field.

      --  If this is an LHS and a variable, there has to be a
      --  declaration, and we either declared it as unsigned or we
      --  did. We did if the condition below is true.

      if Get_Is_LHS (V) and then Is_Variable (V, False) then
         return Opt_Is_Unsigned_Type (BT);
      else
         return Is_A_Get_Element_Ptr_Inst (V) and then Is_Unsigned_GEP (V);
      end if;

   end Is_Unsigned_Ref;

   -----------------
   -- Is_Unsigned --
   -----------------

   function Is_Unsigned (V : Value_T) return Boolean is
      TE : constant Opt_Type_Kind_Id := GNAT_Type (V);
      BT : constant Opt_Type_Kind_Id := Opt_Full_Base_Type (TE);

   begin
      --  Note that what we care about here is whether the C compiler
      --  will interpret our generated code for V as unsigned, not
      --  whether it actually IS unsigned.

      --  If V isn't a LHS but is a variable and we've written a
      --  declaration for it, it's only unsigned if we've written "unsigned"
      --  in the declaration.

      if not Get_Is_LHS (V) and then Is_Variable (V, False)
        and then Get_Is_Decl_Output (V)
      then
         return Opt_Is_Unsigned_Type (BT);

      --  If it's not an instruction, we won't have made it unsigned

      elsif not Is_A_Instruction (V) then
         return False;
      end if;

      --  Now handle instructions that could produce unsigned

      case Get_Opcode (V) is

         --  A load is unsigned iff the pointer is a reference to unsigned

         when Op_Load =>
            return Is_Unsigned_Ref (Get_Operand0 (V));

         --  Some instructions always produce unsigned results

         when Op_U_Div | Op_U_Rem | Op_L_Shr | Op_Z_Ext | Op_FP_To_UI |
              Op_I_Cmp | Op_F_Cmp =>
            return True;

         --  Arithmetic instructions are unsigned if either operand are
         --  (since we know that both operands are the same size).

         when Op_Add | Op_Sub | Op_Mul | Op_And | Op_Or | Op_Xor =>
            return Is_Unsigned (Get_Operand0 (V))
              or else Is_Unsigned (Get_Operand1 (V));

         --  A call instruction is unsigned if the function called is known
         --  and has an unsigned return type.

         when Op_Call =>

            declare
               TE : constant Opt_Type_Kind_Id := GNAT_Type (Get_Operand0 (V));
               BT : constant Opt_Type_Kind_Id := Opt_Full_Base_Type (TE);

            begin
               return Opt_Is_Unsigned_Type (BT);
            end;

         --  Some conversions don't change signedness and neither does left
         --  shift.

         when Op_Bit_Cast | Op_Trunc | Op_Shl =>
            return Is_Unsigned (Get_Operand0 (V));

         when others =>
            null;

      end case;

      --  In all other case, it isn't unsigned

      return False;
   end Is_Unsigned;

   -----------------
   -- Is_Variable --
   -----------------

   function Is_Variable
     (V : Value_T; Need_From_Source : Boolean := True) return Boolean
   is
      E : constant Entity_Id := Get_Entity (V);

   begin
      return Present (E) and then not Is_Type (E) and then Has_Name (V)
        and then (not Need_From_Source or else Comes_From_Source (E));
   end Is_Variable;

   -----------------
   -- Is_Volatile --
   -----------------

   function Is_Volatile (V : Value_T) return Boolean is
      E : constant Entity_Id := Get_Entity (V);

   begin
      return Present (E) and then Treat_As_Volatile (E);
   end Is_Volatile;

   ----------------------
   -- Has_Side_Effects --
   ----------------------

   function Has_Side_Effects (V : Value_T) return Boolean is
   begin
      --  If this isn't an instruction, it doesn't have a side effect. If
      --  it's a call instruction, a terminator, or a load that's either
      --  volatile or not from a variable, it does have side effects.
      --  Otherwise, it has a side effect iff any operand does. We treat a
      --  Phi node as volatile since we can have infinite recursion if we
      --  try to walk its operands.

      return (if not Is_A_Instruction (V) then False
      elsif Is_A_Call_Inst (V) or else Is_APHI_Node (V)
                    or else Is_A_Terminator_Inst (V)
                    or else Is_A_Store_Inst (V)
                    or else (Is_A_Load_Inst (V)
                             and then (Get_Volatile (V)
                                       or else not Is_Variable
                                                     (Get_Operand0 (V))))
              then True
              else (for some J in Nat range 0 .. Get_Num_Operands (V) - 1 =>
                Has_Side_Effects (Get_Operand (V, J))));

   end Has_Side_Effects;

   -----------------
   -- Update_Hash --
   ----------------

   procedure Update_Hash (H : in out Hash_Type; Key : Hash_Type) is
      function Shift_Left
        (Value  : Hash_Type;
         Amount : Natural) return Hash_Type;
      pragma Import (Intrinsic, Shift_Left);
   begin
      H := Key + Shift_Left (H, 6) + Shift_Left (H, 16) - H;
   end Update_Hash;

   -----------------
   -- Update_Hash --
   ----------------

   procedure Update_Hash (H : in out Hash_Type; S : String) is
   begin
      for C of S loop
         Update_Hash (H, Character'Pos (C));
      end loop;
   end Update_Hash;

   -----------------
   -- Update_Hash --
   -----------------

   procedure Update_Hash (H : in out Hash_Type; B : Boolean) is
   begin
      Update_Hash (H, Boolean'Pos (B));
   end Update_Hash;

   -----------------
   -- Update_Hash --
   -----------------

   procedure Update_Hash (H : in out Hash_Type; V : Value_T) is
   begin
      Update_Hash (H, Hash (V));
   end Update_Hash;

   -----------------
   -- Update_Hash --
   -----------------

   procedure Update_Hash (H : in out Hash_Type; T : Type_T) is
   begin
      Update_Hash (H, Hash (T));
   end Update_Hash;

   -----------------
   -- Update_Hash --
   -----------------

   procedure Update_Hash (H : in out Hash_Type; B : Basic_Block_T) is
   begin
      Update_Hash (H, Hash (B));
   end Update_Hash;

   ----------------------
   -- Safe_Single_User --
   ----------------------

   function Safe_Single_User (V : Value_T) return Value_T is
      User : constant Value_T := Single_User (V);
      Next : Value_T;

   begin
      --  If there isn't a unique single user or V isn't an instruction,
      --  we're done.

      if No (User) or else not Is_A_Instruction (V) then
         return No_Value_T;
      end if;

      --  Otherwise try to find User

      Next := Get_Next_Instruction (V);
      while Present (Next) loop

         --  If we've reached User, we're good. If we reached an instruction
         --  with side-effects, we're bad.

         if Next = User then
            return User;
         elsif Has_Side_Effects (Next) then
            return No_Value_T;
         end if;

         Next := Get_Next_Instruction (Next);
      end loop;

      return No_Value_T;

   end Safe_Single_User;

   -------------------------
   -- Equivalent_Pointers --
   -------------------------

   function Equivalent_Pointers (T1, T2 : Type_T) return Boolean is
      E_T1 : constant Type_T := Get_Element_Type (T1);
      E_T2 : constant Type_T := Get_Element_Type (T2);

   begin
      --  True if the types are the same or one points to a zero-length
      --  array whose type is what the other points to.

      return E_T1 = E_T2
        or else (Get_Type_Kind (E_T1) = Array_Type_Kind
                 and then Get_Array_Length (E_T1) = 0
                 and then Get_Element_Type (E_T1) = E_T2)
        or else (Get_Type_Kind (E_T2) = Array_Type_Kind
                 and then Get_Array_Length (E_T2) = 0
                 and then Get_Element_Type (E_T2) = E_T1);

   end Equivalent_Pointers;

---------------------
   -- Int_Type_String --
   ---------------------

   function Int_Type_String (Size : Pos) return Str is
   begin
      --  ??? There are a number of issues here: Ada supports a
      --  "long long long" type, which could correspond to C's
      --  int128_t.  We also may want to generate intXX_t types
      --  instead of the standard types based on a switch.  But for
      --  now we'll keep it simple.

      if Size > Long_Size and then Size > Int_Size
        and then Size <= Long_Long_Size
      then
         return +"long long";
      elsif Size > Int_Size and then Size <= Long_Size then
         return +"long";
      elsif Size > Short_Size and then Size <= Int_Size then
         return +"int";
      elsif Size > Char_Size and then Size <= Short_Size then
         return +"short";
      elsif Size <= Char_Size then
         return +"char";
      else
         return +"<unknown int type:" & Size'Image & ">";
      end if;
   end Int_Type_String;

end CCG.Utils;
