defmodule Surface.API do
  @moduledoc false

  alias Surface.IOHelper

  @types [
    :any,
    :css_class,
    :list,
    :event,
    :boolean,
    :string,
    :date,
    :datetime,
    :number,
    :integer,
    :decimal,
    :map,
    :fun,
    :atom,
    :module,
    :changeset,
    :form,
    :keyword
  ]

  @private_opts [:action, :to]

  defmacro __using__(include: include) do
    arities = %{
      property: [2, 3],
      slot: [1, 2],
      data: [2, 3],
      context: [1]
    }

    functions = for func <- include, arity <- arities[func], into: [], do: {func, arity}

    quote do
      import unquote(__MODULE__), only: unquote(functions)
      @before_compile unquote(__MODULE__)
      @after_compile unquote(__MODULE__)

      Module.register_attribute(__MODULE__, :assigns, accumulate: false)
      # Any caller component can hold other components with slots
      Module.register_attribute(__MODULE__, :assigned_slots_by_parent, accumulate: false)

      for func <- unquote(include) do
        Module.register_attribute(__MODULE__, func, accumulate: true)
        unquote(__MODULE__).init_func(func, __MODULE__)
      end
    end
  end

  defmacro __before_compile__(env) do
    generate_docs(env)

    [
      quoted_property_funcs(env),
      quoted_slot_funcs(env),
      quoted_data_funcs(env),
      quoted_context_funcs(env)
    ]
  end

  def __after_compile__(env, _) do
    if !function_exported?(env.module, :init_context, 1) do
      validate_has_init_context(env)
    end

    if function_exported?(env.module, :__slots__, 0) do
      validate_slot_props_bindings!(env)
      validate_required_slots!(env)
    end
  end

  @doc false
  def init_func(:slot, module) do
    Module.register_attribute(module, :used_slot, accumulate: true)
    :ok
  end

  def init_func(_func, _caller) do
    :ok
  end

  @doc "Defines a property for the component"
  defmacro property(name_ast, type_ast, opts_ast \\ []) do
    build_assign_ast(:property, name_ast, type_ast, opts_ast, __CALLER__)
  end

  @doc "Defines a slot for the component"
  defmacro slot(name_ast, opts_ast \\ []) do
    build_assign_ast(:slot, name_ast, :any, opts_ast, __CALLER__)
  end

  @doc "Defines a data assign for the component"
  defmacro data(name_ast, type_ast, opts_ast \\ []) do
    build_assign_ast(:data, name_ast, type_ast, opts_ast, __CALLER__)
  end

  @doc """
  Sets or retrieves a context assign.

  ### Usage

  ```
    context set name, type, opts \\ []
    context get name, opts
  ```

  ### Examples

  ```
    context set form, :form
    ...
    context get form, from: Form
  ```
  """

  # context get

  defmacro context({:get, _, [name_ast, opts_ast]}) when is_list(opts_ast) do
    opts_ast = [{:action, :get} | opts_ast]
    build_assign_ast(:context, name_ast, :any, opts_ast, __CALLER__)
  end

  defmacro context({:get, _, [_name_ast, type]}) when type in @types do
    message = """
    cannot redefine the type of the assign when using action :get. \
    The type is already defined by a parent component using action :set\
    """

    IOHelper.compile_error(message, __CALLER__.file, __CALLER__.line)
  end

  defmacro context({:get, _, [name_ast, invalid_opts_ast]}) do
    build_assign_ast(:context, name_ast, :any, invalid_opts_ast, __CALLER__)
  end

  defmacro context({:get, _, [name_ast]}) do
    opts_ast = [action: :get]
    build_assign_ast(:context, name_ast, :any, opts_ast, __CALLER__)
  end

  defmacro context({:get, _, nil}) do
    message = """
    no name defined for context get

    Usage: context get name, opts
    """

    IOHelper.compile_error(message, __CALLER__.file, __CALLER__.line)
  end

  # context set

  defmacro context({:set, _, [name_ast, type_ast, opts_ast]}) when is_list(opts_ast) do
    opts_ast = Keyword.merge(opts_ast, action: :set, to: __CALLER__.module)

    build_assign_ast(:context, name_ast, type_ast, opts_ast, __CALLER__)
  end

  defmacro context({:set, _, [_name_ast, opts]}) when is_list(opts) do
    message = "no type defined for context set. Type is required after the name."
    IOHelper.compile_error(message, __CALLER__.file, __CALLER__.line)
  end

  defmacro context({:set, _, [name_ast, type_ast]}) do
    opts_ast = [action: :set, to: __CALLER__.module]

    build_assign_ast(:context, name_ast, type_ast, opts_ast, __CALLER__)
  end

  defmacro context({:set, _, [_name_ast]}) do
    message = "no type defined for context set. Type is required after the name."
    IOHelper.compile_error(message, __CALLER__.file, __CALLER__.line)
  end

  # invalid usage

  defmacro context({_action, _, args}) when length(args) > 2 do
    message = """
    invalid use of context. Usage: `context get name, opts` \
    or `context set name, type, opts \\ []`\
    """

    IOHelper.compile_error(message, __CALLER__.file, __CALLER__.line)
  end

  defmacro context({action, _, _}) do
    message = "invalid context action. Expected :get or :set, got: #{Macro.to_string(action)}"
    IOHelper.compile_error(message, __CALLER__.file, __CALLER__.line)
  end

  @doc false
  def put_assign!(caller, func, name, type, opts, opts_ast, line) do
    Surface.API.validate!(func, name, type, opts, caller)

    assign = %{
      func: func,
      name: name,
      type: type,
      doc: pop_doc(caller.module),
      opts: opts,
      opts_ast: opts_ast,
      line: line
    }

    assigns = Module.get_attribute(caller.module, :assigns) || %{}
    name = Keyword.get(assign.opts, :as, assign.name)
    existing_assign = assigns[name]

    if Keyword.get(assign.opts, :scope) != :only_children do
      if existing_assign do
        message = """
        cannot use name \"#{assign.name}\". There's already \
        a #{existing_assign.func} assign with the same name \
        at line #{existing_assign.line}.#{suggestion_for_duplicated_assign(assign)}\
        """

        IOHelper.compile_error(message, caller.file, assign.line)
      else
        assigns = Map.put(assigns, name, assign)
        Module.put_attribute(caller.module, :assigns, assigns)
      end
    end

    Module.put_attribute(caller.module, assign.func, assign)
  end

  defp suggestion_for_duplicated_assign(%{func: :context, opts: opts}) do
    "\n\nHint: " <>
      case Keyword.get(opts, :action) do
        :set ->
          """
          if you only need this context assign in the child components, \
          you can set option :scope as :only_children to solve the issue.\
          """

        :get ->
          "you can use the :as option to set another name for the context assign."
      end
  end

  defp suggestion_for_duplicated_assign(_assign) do
    ""
  end

  defp quoted_data_funcs(env) do
    data = Module.get_attribute(env.module, :data) || []

    quote do
      @doc false
      def __data__() do
        unquote(Macro.escape(data))
      end
    end
  end

  defp quoted_property_funcs(env) do
    props = Module.get_attribute(env.module, :property) || []
    props_names = Enum.map(props, fn prop -> prop.name end)
    props_by_name = for p <- props, into: %{}, do: {p.name, p}

    quote do
      @doc false
      def __props__() do
        unquote(Macro.escape(props))
      end

      @doc false
      def __validate_prop__(prop) do
        prop in unquote(props_names)
      end

      @doc false
      def __get_prop__(name) do
        Map.get(unquote(Macro.escape(props_by_name)), name)
      end
    end
  end

  defp quoted_slot_funcs(env) do
    used_slots =
      for %{name: name, line: line} <- Module.get_attribute(env.module, :used_slot) || [] do
        %{func: :slot, name: name, type: :any, doc: nil, opts: [], opts_ast: [], line: line}
      end

    slots = (Module.get_attribute(env.module, :slot) || []) ++ used_slots
    slots = Enum.uniq_by(slots, & &1.name)
    slots_names = Enum.map(slots, fn slot -> slot.name end)
    slots_by_name = for p <- slots, into: %{}, do: {p.name, p}

    required_slots_names =
      for %{name: name, opts: opts} <- slots, opts[:required] do
        name
      end

    assigned_slots_by_parent = Module.get_attribute(env.module, :assigned_slots_by_parent) || %{}

    quote do
      @doc false
      def __slots__() do
        unquote(Macro.escape(slots))
      end

      @doc false
      def __validate_slot__(prop) do
        prop in unquote(slots_names)
      end

      @doc false
      def __get_slot__(name) do
        Map.get(unquote(Macro.escape(slots_by_name)), name)
      end

      @doc false
      def __assigned_slots_by_parent__() do
        unquote(Macro.escape(assigned_slots_by_parent))
      end

      @doc false
      def __required_slots_names__() do
        unquote(Macro.escape(required_slots_names))
      end
    end
  end

  defp quoted_context_funcs(env) do
    context = Module.get_attribute(env.module, :context) || []
    {gets, sets} = Enum.split_with(context, fn c -> c.opts[:action] == :get end)
    sets_in_scope = Enum.filter(sets, fn var -> var.opts[:scope] != :only_children end)
    assigns = gets ++ sets_in_scope

    quote do
      @doc false
      def __context_gets__() do
        unquote(Macro.escape(gets))
      end

      @doc false
      def __context_sets__() do
        unquote(Macro.escape(sets))
      end

      @doc false
      def __context_sets_in_scope__() do
        unquote(Macro.escape(sets_in_scope))
      end

      @doc false
      def __context_assigns__() do
        unquote(Macro.escape(assigns))
      end
    end
  end

  def validate!(func, name, type, opts, caller) do
    with :ok <- validate_type(func, name, type),
         :ok <- validate_opts_keys(func, name, type, opts),
         :ok <- validate_opts(func, type, opts),
         :ok <- validate_required_opts(func, type, opts) do
      :ok
    else
      {:error, message} ->
        file = Path.relative_to_cwd(caller.file)
        IOHelper.compile_error(message, file, caller.line)
    end
  end

  defp validate_name_ast!(_func, {name, meta, context}, _caller)
       when is_atom(name) and is_list(meta) and is_atom(context) do
    name
  end

  defp validate_name_ast!(func, name_ast, caller) do
    message = """
    invalid #{func} name. Expected a variable name, got: #{Macro.to_string(name_ast)}\
    """

    IOHelper.compile_error(message, caller.file, caller.line)
  end

  defp validate_type(_func, _name, type) when type in @types do
    :ok
  end

  defp validate_type(func, name, type) do
    message = """
    invalid type #{Macro.to_string(type)} for #{func} #{name}.
    Expected one of #{inspect(@types)}.
    Hint: Use :any if the type is not listed.\
    """

    {:error, message}
  end

  defp validate_opts_keys(func, name, type, opts) do
    with true <- Keyword.keyword?(opts),
         keys <- Keyword.keys(opts),
         valid_opts <- get_valid_opts(func, type, opts),
         [] <- keys -- (valid_opts ++ @private_opts) do
      :ok
    else
      false ->
        {:error,
         "invalid options for #{func} #{name}. " <>
           "Expected a keyword list of options, got: #{inspect(remove_private_opts(opts))}"}

      unknown_options ->
        valid_opts = get_valid_opts(func, type, opts)
        {:error, unknown_options_message(valid_opts, unknown_options)}
    end
  end

  defp validate_opts_ast!(func, opts, caller) when is_list(opts) do
    if Keyword.keyword?(opts) do
      for {key, value} <- opts do
        {key, validate_opt_ast!(func, key, value, caller)}
      end
    else
      opts
    end
  end

  defp validate_opts_ast!(_func, opts, _caller) do
    opts
  end

  defp validate_opts(func, type, opts) do
    Enum.reduce_while(opts, :ok, fn {key, value}, _acc ->
      case validate_opt(func, type, key, value) do
        :ok ->
          {:cont, :ok}

        error ->
          {:halt, error}
      end
    end)
  end

  defp validate_required_opts(func, type, opts) do
    case get_required_opts(func, type, opts) -- Keyword.keys(opts) do
      [] ->
        :ok

      missing_opts ->
        {:error, "the following options are required: #{inspect(missing_opts)}"}
    end
  end

  defp get_valid_opts(:property, _type, _opts) do
    [:required, :default, :values]
  end

  defp get_valid_opts(:data, _type, _opts) do
    [:default, :values]
  end

  defp get_valid_opts(:slot, _type, _opts) do
    [:required, :props]
  end

  defp get_valid_opts(:context, _type, opts) do
    case Keyword.fetch!(opts, :action) do
      :get ->
        [:from, :as]

      :set ->
        [:scope]
    end
  end

  defp get_required_opts(:context, _type, opts) do
    case Keyword.fetch!(opts, :action) do
      :get ->
        [:from]

      _ ->
        []
    end
  end

  defp get_required_opts(_func, _type, _opts) do
    []
  end

  defp validate_opt_ast!(:slot, :props, args_ast, caller) do
    Enum.map(args_ast, fn
      {name, {:^, _, [{generator, _, context}]}} when context in [Elixir, nil] ->
        Macro.escape(%{name: name, generator: generator})

      name when is_atom(name) ->
        Macro.escape(%{name: name, generator: nil})

      ast ->
        message =
          "invalid slot prop #{Macro.to_string(ast)}. " <>
            "Expected an atom or a binding to a generator as `key: ^property_name`"

        IOHelper.compile_error(message, caller.file, caller.line)
    end)
  end

  defp validate_opt_ast!(_func, _key, value, _caller) do
    value
  end

  defp validate_opt(_func, _type, :required, value) when not is_boolean(value) do
    {:error, "invalid value for option :required. Expected a boolean, got: #{inspect(value)}"}
  end

  defp validate_opt(_func, _type, :values, value) when not is_list(value) do
    {:error,
     "invalid value for option :values. Expected a list of values, got: #{inspect(value)}"}
  end

  defp validate_opt(:context, _type, :scope, value)
       when value not in [:only_children, :self_and_children] do
    message = """
    invalid value for option :scope. Expected :only_children or :self_and_children, \
    got: #{inspect(value)}
    """

    {:error, message}
  end

  defp validate_opt(:context, _type, :from, value) when not is_atom(value) do
    {:error, "invalid value for option :from. Expected a module, got: #{inspect(value)}"}
  end

  defp validate_opt(:context, _type, :as, value) when not is_atom(value) do
    {:error, "invalid value for option :as. Expected an atom, got: #{inspect(value)}"}
  end

  defp validate_opt(_func, _type, _key, _value) do
    :ok
  end

  defp unknown_options_message(valid_opts, unknown_options) do
    {plural, unknown_items} =
      case unknown_options do
        [option] ->
          {"", option}

        _ ->
          {"s", unknown_options}
      end

    """
    unknown option#{plural} #{inspect(unknown_items)}. \
    Available options: #{inspect(valid_opts)}\
    """
  end

  defp format_opts(opts_ast) do
    opts_ast
    |> Macro.to_string()
    |> String.slice(1..-2)
  end

  defp generate_docs(env) do
    case Module.get_attribute(env.module, :moduledoc) do
      {_line, false} ->
        :ok

      nil ->
        props_doc = generate_props_docs(env.module)
        Module.put_attribute(env.module, :moduledoc, {env.line, props_doc})

      {line, doc} ->
        props_doc = generate_props_docs(env.module)
        Module.put_attribute(env.module, :moduledoc, {line, doc <> "\n" <> props_doc})
    end
  end

  defp generate_props_docs(module) do
    docs =
      for prop <- Module.get_attribute(module, :property) do
        doc = if prop.doc, do: " - #{prop.doc}.", else: ""
        opts = if prop.opts == [], do: "", else: ", #{format_opts(prop.opts_ast)}"
        "* **#{prop.name}** *#{inspect(prop.type)}#{opts}*#{doc}"
      end
      |> Enum.reverse()
      |> Enum.join("\n")

    """
    ### Properties

    #{docs}
    """
  end

  defp validate_has_init_context(env) do
    for var <- Module.get_attribute(env.module, :context) || [] do
      if Keyword.get(var.opts, :action) == :set do
        message = """
        context assign \"#{var.name}\" not initialized. \
        You should implement an init_context/1 callback and initialize its \
        value by returning {:ok, #{var.name}: ...}\
        """

        IOHelper.warn(message, env, fn _ -> var.line end)
      end
    end

    :ok
  end

  defp validate_slot_props_bindings!(env) do
    for slot <- env.module.__slots__(),
        slot_props = Keyword.get(slot.opts, :props, []),
        %{name: name, generator: generator} <- slot_props,
        generator != nil do
      case env.module.__get_prop__(generator) do
        nil ->
          existing_properties_names = env.module.__props__() |> Enum.map(& &1.name)

          message = """
          cannot bind slot prop `#{name}` to property `#{generator}`. \
          Expected a existing property after `^`, \
          got: an undefined property `#{generator}`.

          Hint: Available properties are #{inspect(existing_properties_names)}\
          """

          IOHelper.compile_error(message, env.file, slot.line)

        %{type: type} when type != :list ->
          message = """
          cannot bind slot prop `#{name}` to property `#{generator}`. \
          Expected a property of type :list after `^`, \
          got: a property of type #{inspect(type)}\
          """

          IOHelper.compile_error(message, env.file, slot.line)

        _ ->
          :ok
      end
    end

    :ok
  end

  defp validate_required_slots!(env) do
    for {{mod, _parent_node_id, parent_node_alias, line}, assigned_slots} <-
          env.module.__assigned_slots_by_parent__(),
        mod != nil,
        name <- mod.__required_slots_names__(),
        !MapSet.member?(assigned_slots, name) do
      message = "missing required slot \"#{name}\" for component <#{parent_node_alias}>"
      IOHelper.warn(message, env, fn _ -> line end)
    end
  end

  defp pop_doc(module) do
    doc =
      case Module.get_attribute(module, :doc) do
        {_, doc} -> doc
        _ -> nil
      end

    Module.delete_attribute(module, :doc)
    doc
  end

  defp build_assign_ast(func, name_ast, type_ast, opts_ast, caller) do
    quote bind_quoted: [
            func: func,
            name: validate_name_ast!(func, name_ast, caller),
            type: type_ast,
            opts: validate_opts_ast!(func, opts_ast, caller),
            opts_ast: Macro.escape(opts_ast),
            line: caller.line
          ] do
      Surface.API.put_assign!(__ENV__, func, name, type, opts, opts_ast, line)
    end
  end

  defp remove_private_opts(opts) do
    if is_list(opts) do
      Enum.reject(opts, fn o -> Enum.any?(@private_opts, fn p -> match?({^p, _}, o) end) end)
    else
      opts
    end
  end
end
