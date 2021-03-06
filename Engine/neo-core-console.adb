
--                                                                                                                                      --
--                                                         N E O  E N G I N E                                                           --
--                                                                                                                                      --
--                                                 Copyright (C) 2016 Justin Squirek                                                    --
--                                                                                                                                      --
-- Neo is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the --
-- Free Software Foundation, either version 3 of the License, or (at your option) any later version.                                    --
--                                                                                                                                      --
-- Neo is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of                --
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.                            --
--                                                                                                                                      --
-- You should have received a copy of the GNU General Public License along with Neo. If not, see gnu.org/licenses                       --
--                                                                                                                                      --

package body Neo.Core.Console is

  --------
  -- IO --
  --------

  -- Internal protected structure of task-safe output
  protected Safe_IO is
      function Log          return Str_Unbound;
      function Input_Entry  return Str_Unbound;
      function Line_Size    return Positive;
      function Lines        return Int_64_Natural;
      procedure Set_Put     (Val  : Ptr_Procedure_Put);
      procedure Line_Size   (Val  : Positive);
      procedure Input_Entry (Val  : Str_Unbound);
      procedure Put         (Item : Str);
    private
      Current_Put         : Ptr_Procedure_Put := null;
      Current_Log         : Str_Unbound       := NULL_STR_UNBOUND;
      Current_Input_Entry : Str_Unbound       := NULL_STR_UNBOUND;
      Current_Lines       : Int_64_Natural    := 0;
      Current_Tasks       : Positive          := 1;
      Current_Line_Size   : Positive          := 80;
    end;
  protected body Safe_IO is
      function Log          return Str_Unbound        is (Current_Log);
      function Input_Entry  return Str_Unbound        is (Current_Input_Entry);
      function Line_Size    return Positive           is (Current_Line_Size);
      function Lines        return Int_64_Natural     is (Current_Lines);
      procedure Set_Put     (Val : Ptr_Procedure_Put) is begin Current_Put         := Val; end;
      procedure Line_Size   (Val : Positive)          is begin Current_Line_Size   := Val; end;
      procedure Input_Entry (Val : Str_Unbound)       is begin Current_Input_Entry := Val; end;
      procedure Put (Item : Str) is
        begin
          Current_Log := Current_Log & Item;
          if Current_Put /= null then Current_Put.All (Item); end if;
          
          -- Count new lines
          for I of Item loop
            if I = To_Char_16 (ASCII.CR) then Current_Lines := Current_Lines + 1; end if;
          end loop;
        end;
    end;

  -- Public Safe_IO interface to wrap the protected type
  procedure Use_Ada_Put                                    is begin Set_Put (Ada_IO.Put'Access);   end; 
  procedure Input_Entry (Val  : Str)                       is begin Safe_IO.Input_Entry (U (Val)); end;
  procedure Line_Size   (Val  : Positive)                  is begin Safe_IO.Line_Size (Val);       end;
  procedure Set_Put     (Val  : Ptr_Procedure_Put)         is begin Safe_IO.Set_Put (Val);         end;
  procedure Put         (Item : Str_Unbound)               is begin Put (S (Item));                end;
  procedure Put         (Item : Char)                      is begin Put (Item & "");               end;                  
  procedure Put         (Item : Str)                       is begin Safe_IO.Put (Item);            end;
  procedure Line        (Item : Char)                      is begin Line (Item & "");              end;    
  procedure Line        (Item : Str_Unbound)               is begin Line (S (Item));               end;
  procedure Line        (Item : Str := "")                 is begin Put (Item & EOL);              end;
  function Extension    (Path : Str) return Str            is (Path (Index (Path, ".") + 1..Path'Last));
  function Log                       return Str_Unbound    is (Safe_IO.Log);
  function Input_Entry               return Str            is (S (Safe_IO.Input_Entry)); 
  function Lines                     return Int_64_Natural is (Safe_IO.Lines);
  function Line_Size                 return Positive       is (Safe_IO.Line_Size);

  --------------------
  -- Internal State --
  --------------------

   FEEDBACK_PREFIX : constant Str := ">>> ";
   
  -- Internal data structures
  type Command_State is record 
      Save     : access function return Str := null;
      Callback : access procedure (Args : Array_Str_Unbound) := null;
    end record;
  type CVar_State is record 
      Val : Str_Unbound := NULL_STR_UNBOUND; -- A cvar that goes out of scope is not forgotten
      Get : access function return Str := null;
      Set : access procedure (Val : Str) := null;
   end record;

  -- Data types
  package Hashed_CVar    is new Hashed (CVar_State);
  package Hashed_Command is new Hashed (Command_State);
  use Hashed_CVar.Unsafe; use Hashed_Command.Unsafe;

  -- Global maps
  Commands : Hashed_Command.Safe_Map;
  CVars    : Hashed_CVar.Safe_Map;

  -------------------
  -- Internal CVar --
  -------------------
  --
  -- Common functionality shared between different CVar kinds - registration and deletion from the global CVars
  --

  generic
    Name     : Str;
    type Var_T is private;
    Initial  : Var_T;
    Settable : Bool := True;
    with procedure Handle_Set (Val : Str);
    with function Handle_Get return Str;
    with procedure Set (Val : Var_T);
    with function Get return Var_T;
    with function To_Str_Unbound (Val : Var_T) return Str_Unbound; -- Because 'Image only works on scalar things...
  package CVar_Internal is end;

  package body CVar_Internal is
      Duplicate, Parse : Exception;

      procedure Informal_Handle_Set (Val : Str) renames Handle_Set;
      function Informal_Handle_Get return Str renames Handle_Get;

      -- Controller
      type Control_State is new Limited_Controlled with null record;
      procedure Initialize (Control : in out Control_State);
      procedure Finalize   (Control : in out Control_State);
      procedure Initialize (Control : in out Control_State) is
        begin
          if Commands.Has (Name) then
            if CVars.Get (Name).Set /= null or CVars.Get (Name).Get /= null then raise Duplicate; end if;
            CVars.Replace (Name, (Val => CVars.Get (Name).Val,
                                  Get => Informal_Handle_Get'Unrestricted_Access,
                                  Set => Informal_Handle_Set'Unrestricted_Access));
            Handle_Set (S (CVars.Get (Name).Val));
          else
            CVars.Insert (Name, (Val => NULL_STR_UNBOUND,
                                 Get => Informal_Handle_Get'Unrestricted_Access,
                                 Set => Informal_Handle_Set'Unrestricted_Access));
            Set (Initial);
          end if;
        end;
      procedure Finalize (Control : in out Control_State) is
        begin
          Line ("There is a finalization bug here, because this is never called!"); -- !!!
          Line (S (To_Str_Unbound (Get)));
          if Settable then CVars.Replace (Name, (Val => To_Str_Unbound (Get),
                                                 Get => null,
                                                 Set => null));
          else CVars.Delete (Name); end if;
        end;
      Controller : Control_State;
    end;

  ----------
  -- CVar --
  ----------

  -- Maximum cvar values displayable after query
  MAX_VALUES_DISPLAYABLE : constant Positive := 5; 

  package body CVar is
      
      -- Internal data
      protected Safe_Var_T with Lock_Free is
          function Get return Var_T;
          procedure Set (Val : Var_T);
        private
          Current : Var_T;
        end;
      protected body Safe_Var_T is
          function Get return Var_T is (Current);
          procedure Set (Val : Var_T) is begin Current := Val; end;
        end;

      -- Accessors
      function Get return Var_T is (Safe_Var_T.Get);
      procedure Set (Val : Var_T) is begin Safe_Var_T.Set (Val); end;
      function S (Val : Var_T) return Str is (To_Str (Trim (Get'Img, Both)));
      function To_Str_Unbound (Val : Var_T) return Str_Unbound is (To_Str_Unbound (Trim (Get'Img, Both)));

      -- Commandline interaction
      function Handle_Get return Str is
        Vals : Str_Unbound := NULL_STR_UNBOUND;
        begin
          if Var_T'Pos (Var_T'Last) - Var_T'Pos (Var_T'First) > MAX_VALUES_DISPLAYABLE then
            Vals := U (Var_T'First'Wide_Image & " .." & Var_T'Last'Wide_Image);
          else
            for I in Var_T'Range loop
              Vals := Vals & ", " & To_Str_Unbound (I);
            end loop;
          end if;
          return FEEDBACK_PREFIX & Help & EOL &
                 FEEDBACK_PREFIX & "Current value: " & S (Get) & EOL &
                 FEEDBACK_PREFIX & (if Settable then "Possible values: " & S (Vals) else NULL_STR);
        end;
      procedure Handle_Set (Val : Str) is
        begin
          if not Settable then
            Line (Name & " is not settable!");
            return;
          end if;
          Set (Var_T'Wide_Value (Val));
        exception when Constraint_Error =>
          for I in Var_T'Range loop
            if Val = S (I) then
              Set (I);
              exit;
            elsif I = Var_T'Last then
              Line (FEEDBACK_PREFIX & "Incorrect parameter for cvar """ & Name & """: " & Val);
              Line (Handle_Get);
            end if;
          end loop;
        end;

      -- Global registration
      package Internal is new CVar_Internal (Name, Var_T, Initial, Settable, Handle_Set, Handle_Get, Set, Get, To_Str_Unbound);
    end;

  ---------------
  -- CVar_Real --
  ---------------

  package body CVar_Real is

      -- Internal data
      protected Safe_Var_T with Lock_Free is
          function Get return Var_T;
          procedure Set (Val : Var_T);
        private
          Current : Var_T;
        end;
      protected body Safe_Var_T is
          function Get return Var_T is (Current);
          procedure Set (Val : Var_T) is begin Current := Val; end;
        end;

      -- Accessors
      function Get return Var_T is (Safe_Var_T.Get);
      procedure Set (Val : Var_T) is begin Safe_Var_T.Set (Val); end;
      function S (Val : Var_T) return Str is (To_Str (Trim (Get'Img, Both)));
      function To_Str_Unbound (Val : Var_T) return Str_Unbound is (To_Str_Unbound (Trim (Get'Img, Both)));

      -- Commandline interaction
      function Handle_Get return Str is
        (FEEDBACK_PREFIX & Help & EOL &
         FEEDBACK_PREFIX & "Current value: " & S (Get) & EOL &
         FEEDBACK_PREFIX & "Possible values: " & S (Var_T'First) & ".." & S (Var_T'Last));
      procedure Handle_Set (Val : Str) is
        begin
          if not Settable then
            Line (FEEDBACK_PREFIX & Name & " is not settable!");
            return;
          end if;
          Set (Var_T'Wide_Value (Val));
        exception when Constraint_Error =>
          Line (FEEDBACK_PREFIX & "Incorrect parameter for cvar """ & Name & """: " & Val);
          Line (Handle_Get);
        end;

      -- Global registration
      package Internal is new CVar_Internal (Name, Var_T, Initial, Settable, Handle_Set, Handle_Get, Set, Get, To_Str_Unbound);
    end;

  --------------
  -- CVar_Str --
  --------------

  package body CVar_Str is

      -- Internal data
      protected Safe_Var_T is
          function Get return Str_Unbound;
          procedure Set (Val : Str_Unbound);
        private
          Current : Str_Unbound;
        end;
      protected body Safe_Var_T is
          function Get return Str_Unbound is (Current);
          procedure Set (Val : Str_Unbound) is begin Current := Val; end;
        end;

      -- Accessors
      function Get return Str is (S (Safe_Var_T.Get));
      function Get return Str_Unbound is (Safe_Var_T.Get);
      procedure Set (Val : Str) is begin Safe_Var_T.Set (To_Str_Unbound (Val)); end;
      procedure Set (Val : Str_Unbound) is begin Safe_Var_T.Set (Val); end;
      function To_Str_Unbound (Val : Str_Unbound) return Str_Unbound is (Val);

      -- Commandline interaction
      function Handle_Get return Str is (FEEDBACK_PREFIX & Help & EOL & FEEDBACK_PREFIX & "cCurrent value: " & Get);
      procedure Handle_Set (Val : Str) is
        begin
          if not Settable then
            Line (FEEDBACK_PREFIX & Name & " is not settable!");
            return;
          end if;
          Set (Val);
        end;

      -- Global registration
      package Internal is new
        CVar_Internal (Name, Str_Unbound, To_Str_Unbound (Initial), Settable, Handle_Set, Handle_Get, Set, Get, To_Str_Unbound);
    end;

  -------------
  -- Command --
  -------------

  package body Command is
      Duplicate, Parse : Exception;

      -- Callback is a generic formal so a rename needs to be present to pass out function pointers
      procedure Informal_Callback (Args : Array_Str_Unbound) renames Callback; 

      -- Controller
      type Control_State is new Controlled with null record;
      procedure Finalize   (Control : in out Control_State);
      procedure Initialize (Control : in out Control_State);
      procedure Finalize   (Control : in out Control_State) is begin Commands.Delete (Name); end;
      procedure Initialize (Control : in out Control_State) is
        begin
          if Commands.Has (Name) then raise Duplicate; end if;
          Commands.Insert (Name, (Save, Informal_Callback'Unrestricted_Access));
        end;
      Controller : Control_State;
    end;

  -- Input entry parsing
  procedure Submit (Text : Str) is
    Tokens : Array_Str_Unbound := Split (Text);
    CMD    : constant Str := S (Tokens (1));
    begin
      if Commands.Has (CMD) then Commands.Get (CMD).Callback.All (Tokens (2..Tokens'Length));
      elsif CVars.Has (CMD) then
        if Tokens'Length = 1 then
          if CVars.Get (CMD).Get /= null then Line (CVars.Get (CMD).Get.All); end if;
        elsif CVars.Get (CMD).Set /= null then CVars.Get (CMD).Set.All (S (Tokens (2))); end if;
      else raise Constraint_Error; end if;
    exception when others => Line (FEEDBACK_PREFIX & "No such cvar or command!"); end;

  -- Autocomplete aid
  function Autocomplete (Text : Str) return Array_Str_Unbound is
    Result : Vector_Str_Unbound.Unsafe.Vector;
    begin
      for CVar of CVars.Keys loop
        if S (CVar) (1..Text'Length) = Text then Result.Append (CVar); end if;
      end loop;
      return Vector_Str_Unbound.To_Unsafe_Array (Result);
    end;

  ------------------
  -- Localization --
  ------------------

  -- Data types
  package Hashed_Language is new Hashed (Str_Unbound);                use Hashed_Language.Unsafe;
  package Hashed_Locale   is new Hashed (Hashed_Language.Unsafe.Map); use Hashed_Locale.Unsafe; 
  
  -- Initialization
  function Initialize_Localization return Hashed_Locale.Unsafe.Map is
    function Split_Columns (Text : Str) return Vector_Str_Unbound.Unsafe.Vector is
      Result     : Vector_Str_Unbound.Unsafe.Vector;
      begin
        return Result;
      end;
    package Hashed_Indexes is new Hashed (Positive);
    J         : Int  := 1;
    In_Column : Bool := True;
    In_Quote  : Bool := False;
    Column    : Str_Unbound;
    Data      : Ada_IO.File_Type;
    Indexes   : Hashed_Indexes.Unsafe.Map;
    Locales   : Hashed_Locale.Unsafe.Map;
    Language  : Hashed_Language.Unsafe.Map;
    Entries   : Vector_Str_Unbound.Unsafe.Vector;
    ENG       : constant Str_Unbound := To_Str_Unbound ("eng" & NULL_STR);
    begin
      Ada_IO.Open (Data, Ada_IO.In_File, To_Str_8 (App_Path.Get & S & PATH_LOCALE)); -- Str_8 !!!
      --for I of Split (Ada_IO.Get_Line (Data), ",") loop
      --  Indexes.Insert (I, J);
      --  Locales.Insert (I, Language);
      --  J := J + 1;
      --end loop;
      while not Ada_IO.End_Of_File (Data) loop
        for I of Ada_IO.Get_Line (Data) loop
          case I is
            when '"' =>
              if not In_Quote then
                Column   := NULL_STR_UNBOUND;
                In_Quote := True;
              else
                Entries.Append (Column);
                Column    := NULL_STR_UNBOUND;
                In_Quote  := False;
                In_Column := False;
              end if;
            when ',' =>
              if In_Quote then Column := Column & I;
              elsif not In_Column then In_Column := True;
              else
                Entries.Append (Trim (Column, Both));
                Column := NULL_STR_UNBOUND;
              end if;
            when others => Column := Column & I;
          end case;
        end loop;
        if Trim (Column, Both) /= NULL_STR_UNBOUND then Entries.Append (Trim (Column, Both)); end if;
        for I in Locales.Iterate loop
          Language := Element (I);
          Language.Insert (Entries (Indexes.Element (ENG)), (if Int (Entries.Length) >= Indexes.Element (Key (I)) then
                                                               Entries (Indexes.Element (Key (I)))
                                                             else NULL_STR_UNBOUND));
          Locales.Replace (Key (I), Language);
        end loop;
      end loop;
      Ada_IO.Close (Data);
      return Locales;
    exception when others => return Locales; end;

  -- Initalized data
  LOCALE : Hashed_Locale.Unsafe.Map; -- := Initialize_Localization;

  -- Locale lookup
  function Localize (Item : Str) return Str is
    CODE : constant Language_Code := Language;
    LANG : constant Str_Unbound   := To_Str_Unbound (CODE (1) & CODE (2) & CODE (3)); -- This is stupid...
    begin
      return (if S (LANG) /= "eng"
                and then LOCALE.Contains (LANG)
                and then LOCALE.Element (LANG).Contains (To_Str_Unbound (Item))
              then S (LOCALE.Element (LANG).Element (To_Str_Unbound (Item)))
              else Item);
    end;

  -------------------
  -- Configuration --
  -------------------
  
  type Control_State is new Controlled with null record;
  procedure Initialize (Control : in out Control_State);
  procedure Finalize   (Control : in out Control_State);
  procedure Initialize (Control : in out Control_State) is
    Data : Ada_IO.File_Type;
    I    : Natural     := 0;
    Text : Str_Unbound := NULL_STR_UNBOUND;
    begin
      Ada_IO.Open (Data, Ada_IO.In_File, To_Str_8 (App_Path.Get & S & PATH_CONFIG)); -- Str_8 !!!
      while not Ada_IO.End_Of_File (Data) loop
        Text := To_Str_Unbound (Ada_IO.Get_Line (Data));
        I    := Index (Text, "--");
        if I = 0 then Submit (S (Text));
        elsif I /= 1 then Submit (S (Text) (1..I - 1)); end if;
      end loop;
    exception when others => null; end; -- No configuration file.. use defaults
  procedure Finalize (Control : in out Control_State) is
    Data : Ada_IO.File_Type;
    begin
      Ada_IO.Open (Data, Ada_IO.Out_File, To_Str_8 (App_Path.Get & S & PATH_CONFIG)); -- Str_8 !!!

      -- Header
      Ada_IO.Put_Line (Data, "-- " & NAME_ID & " " & VERSION & " config: " & To_Str (Image (Get_Start_Time)));
      Ada_IO.Put_Line (Data, "-- To restore default values simply delete this file.");
      Ada_IO.New_Line (Data);
      Ada_IO.Put_Line (Data, "-- CVars");

      -- CVars NOTE: This fails due to finalization bug !!!
      for I in CVars.Get.Iterate loop Ada_IO.Put_Line (Data, S (Key (I) & " " & Element (I).Val)); end loop;

      -- Commands
      for I in Commands.Get.Iterate loop
        if Element (I).Save /= null then 
          Ada_IO.New_Line (Data);
          Ada_IO.Put_Line (Data, "-- " & S (Key (I)));
          Ada_IO.Put_Line (Data, Element (I).Save.All);
        end if;
      end loop;
      Ada_IO.Close (Data);
    exception when others => Line ("Configuration save failed!"); end;
    Controller : Control_State;
end;
