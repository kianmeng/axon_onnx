defmodule AxonOnnx.Deserialize do
  alias Onnx.ModelProto, as: Model
  alias Onnx.GraphProto, as: Graph
  alias Onnx.ValueInfoProto, as: Value
  alias Onnx.AttributeProto, as: Attribute
  alias Onnx.NodeProto, as: Node
  alias Onnx.TypeProto, as: Type
  alias Onnx.TensorProto, as: Tensor
  alias Onnx.TypeProto.Tensor, as: Placeholder
  alias Onnx.TensorShapeProto, as: Shape
  alias Onnx.TensorShapeProto.Dimension, as: Dimension

  require Logger

  import AxonOnnx.Shared

  def __import__(file, opts \\ []) do
    file
    |> File.read!()
    |> Model.decode!()
    |> to_axon(opts)
  end

  defp to_axon(%Model{graph: %Graph{} = graph}, dimensions) do
    {graph, params} = graph_to_axon(graph, dimensions)

    case graph do
      [graph] ->
        # single-output
        {graph, params}

      graph when is_list(graph) ->
        # multi-output
        {Axon.container(List.to_tuple(graph)), params}
    end
  end

  def graph_to_axon(%Graph{node: nodes} = graph, dimensions) do
    params = get_params(graph)
    inputs = get_inputs(graph, params, dimensions)
    outputs = get_outputs(graph)
    {nodes, _, params} = get_nodes(nodes, inputs, params, %{})
    {Enum.map(outputs, fn name -> nodes[name] end), params}
  end

  defp get_inputs(%Graph{input: inputs}, params, dimensions) do
    Enum.reduce(inputs, %{}, fn %Value{name: name, type: %Type{value: value}}, acc ->
      if Map.has_key?(params, name) do
        acc
      else
        case value do
          {:tensor_type, %Placeholder{} = tensor} ->
            input_shape = shape!(tensor, dimensions)
            Map.put(acc, name, Axon.input(input_shape, name: name))

          unsupported ->
            raise ArgumentError, "unsupported input type #{inspect(unsupported)}"
        end
      end
    end)
  end

  defp get_params(%Graph{initializer: initializer}) do
    Enum.reduce(initializer, %{}, fn %Tensor{name: name} = tensor, params ->
      Map.put(params, name, tensor!(tensor))
    end)
  end

  defp get_outputs(%Graph{output: outputs}) do
    Enum.map(outputs, fn %Value{name: name} -> name end)
  end

  defp get_nodes(pruned_nodes, inp, params, used_params) do
    Enum.reduce(pruned_nodes, {inp, params, used_params}, &recur_nodes/2)
  end

  @nx_op_types [
    {"Abs", &Nx.abs/1},
    {"Acos", &Nx.acos/1},
    {"Acosh", &Nx.acosh/1},
    {"Asin", &Nx.asin/1},
    {"Asinh", &Nx.asinh/1},
    {"Atan", &Nx.atan/1},
    {"Atanh", &Nx.atanh/1},
    {"Ceil", &Nx.ceil/1},
    {"Cos", &Nx.cos/1},
    {"Cosh", &Nx.cosh/1},
    {"Erf", &Nx.erf/1},
    {"Floor", &Nx.floor/1},
    {"HardSwish", &hardswish/1},
    {"Identity", &identity/1},
    {"Log", &Nx.log/1},
    {"Neg", &Nx.negate/1},
    {"Not", &Nx.logical_not/1},
    {"Round", &Nx.round/1},
    {"Reciprocal", &reciprocal/1},
    {"Sign", &Nx.sign/1},
    {"Sin", &Nx.sin/1},
    {"Sinh", &Nx.sinh/1},
    {"Sqrt", &Nx.sqrt/1},
    {"Tan", &Nx.tan/1}
  ]

  for {op, fun} <- @nx_op_types do
    defp recur_nodes(
           %Node{op_type: unquote(op), input: [input], output: [output_name]},
           {axon, params, used_params}
         ) do
      axon_input = axon!(input, axon)

      axon_output =
        case axon_input do
          %Axon{op: :constant, opts: [value: value]} ->
            new_value = apply(unquote(fun), [value])
            Axon.constant(new_value, name: output_name)

          %Axon{} = axon_input ->
            Axon.nx(axon_input, unquote(fun), name: output_name)
        end

      updated_axon = Map.put(axon, output_name, axon_output)
      {updated_axon, params, used_params}
    end
  end

  @activation_op_types [
    {"Celu", :celu, [alpha: {"alpha", 1.0}]},
    {"Elu", :elu, [alpha: {"alpha", 1.0}]},
    {"Exp", :exp, []},
    {"HardSigmoid", :hard_sigmoid, [alpha: {"alpha", 0.2}, beta: {"beta", 0.5}]},
    {"LeakyRelu", :leaky_relu, [alpha: {"alpha", 1.0e-2}]},
    {"LogSoftmax", :log_softmax, [axis: {"axis", -1}]},
    {"Relu", :relu, []},
    {"Selu", :selu,
     [alpha: {"alpha", 1.67326319217681884765625}, gamma: {"gamma", 1.05070102214813232421875}]},
    {"Sigmoid", :sigmoid, []},
    {"Softmax", :softmax, [axis: {"axis", -1}]},
    {"Softplus", :softplus, []},
    {"Softsign", :softsign, []},
    {"Tanh", :tanh, []}
  ]

  for {op, act, act_opts} <- @activation_op_types do
    defp recur_nodes(
           %Node{op_type: unquote(op), attribute: attrs, input: [input], output: [output_name]},
           {axon, params, used_params}
         ) do
      axon_input = axon!(input, axon)
      activation_options = options!(attrs)

      opts =
        Enum.map(unquote(act_opts), fn {k, {name, default}} ->
          if activation_options[name] do
            {k, activation_options[name]}
          else
            {k, default}
          end
        end)

      axon_output =
        case axon_input do
          %Axon{op: :constant, opts: [value: value]} ->
            new_value = apply(Axon.Activations, unquote(act), [value] ++ opts)
            Axon.constant(new_value, name: output_name)

          %Axon{} = axon_input ->
            opts = [name: output_name] ++ opts
            apply(Axon, unquote(act), [axon_input, opts])
        end

      updated_axon = Map.put(axon, output_name, axon_output)
      {updated_axon, params, used_params}
    end
  end

  @reduction_op_types [
    {"ArgMax", &Nx.argmax/2, :axis},
    {"ArgMin", &Nx.argmin/2, :axis},
    {"ReduceL1", &l1_norm/2, :axes},
    {"ReduceL2", &l2_norm/2, :axes},
    {"ReduceLogSum", &logsum/2, :axes},
    {"ReduceLogSumExp", &logsumexp/2, :axes},
    {"ReduceMax", &Nx.reduce_max/2, :axes},
    {"ReduceMean", &Nx.mean/2, :axes},
    {"ReduceMin", &Nx.reduce_min/2, :axes},
    {"ReduceProd", &Nx.product/2, :axes},
    {"ReduceSumSquare", &sumsquare/2, :axes}
  ]

  for {op, reduce_fun, axis_or_axes} <- @reduction_op_types do
    defp recur_nodes(
           %Node{op_type: unquote(op), attribute: attrs, input: [input], output: [output_name]},
           {axon, params, used_params}
         ) do
      reduce_options = options!(attrs)

      %Axon{output_shape: shape} = axon_input = axon!(input, axon)

      keepdims = reduce_options["keepdims"] || 1
      keep_axes = if keepdims == 1, do: true, else: false

      axes =
        if unquote(axis_or_axes) == :axis do
          axis = reduce_options["axis"] || 0
          Nx.Shape.normalize_axis(shape, axis, List.duplicate(nil, Nx.rank(shape) - 1))
        else
          axes = reduce_options["axes"] || Nx.axes(shape)
          Nx.Shape.normalize_axes(shape, axes, List.duplicate(nil, Nx.rank(shape) - 1))
        end

      opts =
        if unquote(axis_or_axes) == :axis do
          last_index = reduce_options["select_last_index"] || 0
          tie_break = if last_index == 0, do: :low, else: :high
          [keep_axis: keep_axes, axis: axes, tie_break: tie_break]
        else
          [keep_axes: keep_axes, axes: axes]
        end

      layer_fun = fn x, _params, opts -> apply(unquote(reduce_fun), [x, opts]) end

      layer =
        case axon_input do
          %Axon{op: :constant, opts: [value: tensor]} ->
            new_value = layer_fun.(tensor, %{}, opts)
            Axon.constant(new_value, name: output_name)

          %Axon{} = axon_input ->
            Axon.layer(axon_input, layer_fun, %{}, output_name, [layer_op: unquote(op)] ++ opts)
        end

      updated_axon = Map.put(axon, output_name, layer)

      {updated_axon, params, used_params}
    end
  end

  @builtin_binary_op_types [
    {"Add", :add},
    {"Sub", :subtract},
    {"Mul", :multiply}
  ]

  for {op, binary_op} <- @builtin_binary_op_types do
    defp recur_nodes(
           %Node{op_type: unquote(op), input: [inp1, inp2], output: [output_name]},
           {axon, params, used_params}
         ) do
      # There's a potential this is just a bias add, so we check if
      # inp1 is a graph node and inp2 is a parameter and handle
      # accordingly
      if unquote(op) == "Add" and Map.has_key?(axon, inp1) and Map.has_key?(params, inp2) do
        inp1 = axon!(inp1, axon)
        inp2 = param!(inp2, params)

        updated_axon = Map.put(axon, output_name, Axon.bias(inp1, name: output_name))
        updated_params = Map.put(used_params, output_name, %{"bias" => inp2})

        {updated_axon, params, updated_params}
      else
        inp1 = input!(inp1, axon, params)
        inp2 = input!(inp2, axon, params)

        {updated_axon, updated_params} =
          case {inp1, inp2} do
            {%Axon{op: :constant, opts: [value: v1]}, %Axon{op: :constant, opts: [value: v2]}} ->
              new_value = apply(Nx, unquote(binary_op), [v1, v2])
              layer = Axon.constant(new_value, name: output_name)
              updated_axon = Map.put(axon, output_name, layer)
              {updated_axon, used_params}

            {%Axon{} = inp1, %Axon{} = inp2} ->
              layer = apply(Axon, unquote(binary_op), [inp1, inp2])
              updated_axon = Map.put(axon, output_name, layer)
              {updated_axon, used_params}

            {%Axon{} = inp1, %Nx.Tensor{} = inp2} ->
              layer =
                trainable_binary_layer(inp1, inp2, unquote(binary_op), output_name, unquote(op))

              updated_axon = Map.put(axon, output_name, layer)
              updated_params = Map.put(used_params, output_name, %{"kernel" => inp2})
              {updated_axon, updated_params}

            {%Nx.Tensor{} = inp1, %Axon{} = inp2} ->
              layer =
                trainable_binary_layer(inp2, inp1, unquote(binary_op), output_name, unquote(op))

              updated_axon = Map.put(axon, output_name, layer)
              updated_params = Map.put(used_params, output_name, %{"kernel" => inp1})
              {updated_axon, updated_params}
          end

        {updated_axon, params, updated_params}
      end
    end
  end

  @binary_op_types [
    {"And", &Nx.logical_and/2},
    # {"BitShift", &bitshift/2},
    {"Div", &Nx.divide/2},
    {"Equal", &Nx.equal/2},
    {"Greater", &Nx.greater/2},
    {"GreaterOrEqual", &Nx.greater_equal/2},
    {"Less", &Nx.less/2},
    {"LessOrEqual", &Nx.less_equal/2},
    {"Mod", &Nx.remainder/2},
    {"Or", &Nx.logical_or/2},
    {"Pow", &Nx.power/2},
    {"Xor", &Nx.logical_xor/2}
  ]

  for {op, binary_fun} <- @binary_op_types do
    defp recur_nodes(
           %Node{op_type: unquote(op), input: [inp1, inp2], output: [output_name]},
           {axon, params, used_params}
         ) do
      inp1 = input!(inp1, axon, params)
      inp2 = input!(inp2, axon, params)

      fun = fn x, y, _params -> apply(unquote(binary_fun), [x, y]) end

      updated_axon =
        case {inp1, inp2} do
          {%Axon{op: :constant, opts: [value: v1]}, %Axon{op: :constant, opts: [value: v2]}} ->
            new_value = apply(unquote(binary_fun), [v1, v2])
            Map.put(axon, output_name, Axon.constant(new_value, name: output_name))

          {%Axon{op: :constant, opts: [value: v1]}, %Nx.Tensor{} = v2} ->
            new_value = apply(unquote(binary_fun), [v1, v2])
            Map.put(axon, output_name, Axon.constant(new_value, name: output_name))

          {%Nx.Tensor{} = v1, %Axon{op: :constant, opts: [value: v2]}} ->
            new_value = apply(unquote(binary_fun), [v1, v2])
            Map.put(axon, output_name, Axon.constant(new_value, name: output_name))

          {%Axon{} = inp1, %Axon{} = inp2} ->
            layer = Axon.layer([inp1, inp2], fun, %{}, output_name, layer_op: unquote(op))
            Map.put(axon, output_name, layer)
        end

      {updated_axon, params, used_params}
    end
  end

  @global_pool_types [
    {"GlobalAveragePool", :global_avg_pool},
    {"GlobalLpPool", :global_lp_pool},
    {"GlobalMaxPool", :global_max_pool}
  ]

  for {op, global_pool_op} <- @global_pool_types do
    defp recur_nodes(
           %Node{op_type: unquote(op), attribute: attrs, input: [input], output: [output_name]},
           {axon, params, used_params}
         ) do
      opts =
        if unquote(op) == "GlobalLpPool" do
          lp_pool_options = options!(attrs)
          [name: output_name, keep_axes: true, norm: lp_pool_options["p"]]
        else
          [name: output_name, keep_axes: true]
        end

      inp = axon!(input, axon)
      layer = apply(Axon, unquote(global_pool_op), [inp, opts])
      updated_axon = Map.put(axon, output_name, layer)

      {updated_axon, params, used_params}
    end
  end

  @variadic_op_types [
    {"Max", &Nx.max/2},
    {"Mean", &mean/2},
    {"Min", &Nx.min/2},
    {"Sum", &Nx.add/2}
  ]
  for {op, variadic_op} <- @variadic_op_types do
    defp recur_nodes(
           %Node{op_type: unquote(op), input: inputs, output: [output_name]},
           {axon, params, used_params}
         ) do
      inputs = Enum.map(inputs, &input!(&1, axon, params))

      fun = fn inputs, _params ->
        [init | rest] = inputs |> Tuple.to_list()

        Enum.reduce(rest, init, fn x, y ->
          apply(unquote(variadic_op), [x, y])
        end)
      end

      layer =
        Axon.layer(Axon.container(List.to_tuple(inputs)), fun, %{}, output_name,
          layer_op: unquote(op)
        )

      updated_axon = Map.put(axon, output_name, layer)

      {updated_axon, params, used_params}
    end
  end

  defp recur_nodes(
         %Node{op_type: "Cast", attribute: attrs, input: [input], output: [output_name]},
         {axon, params, used_params}
       ) do
    cast_options = options!(attrs)
    inp = axon!(input, axon)
    nx_type = onnx_type_to_nx_type(cast_options["to"])

    updated_axon =
      case inp do
        %Axon{op: :constant, opts: [value: v]} ->
          new_value = Nx.as_type(v, nx_type)
          Map.put(axon, output_name, Axon.constant(new_value, name: output_name))

        %Axon{} = inp ->
          layer = Axon.nx(inp, &Nx.as_type(&1, nx_type), name: output_name)
          Map.put(axon, output_name, layer)
      end

    {updated_axon, params, used_params}
  end

  defp recur_nodes(
         %Node{op_type: "LRN", input: [input], attribute: attrs, output: [output_name]},
         {axon, params, used_params}
       ) do
    inp = axon!(input, axon)
    lrn_options = options!(attrs)
    opts = Enum.map(lrn_options, fn {k, v} -> {String.to_atom(k), v} end)

    layer = Axon.nx(inp, &lrn(&1, opts), name: output_name)
    updated_axon = Map.put(axon, output_name, layer)
    {updated_axon, params, used_params}
  end

  defp recur_nodes(
         %Node{op_type: "Gather", input: [x, ind], output: [output_name], attribute: attrs},
         {axon, params, used_params}
       ) do
    x = input!(x, axon, params)
    ind = input!(ind, axon, params)
    gather_options = options!(attrs)

    {updated_axon, updated_params} =
      case {x, ind} do
        {%Nx.Tensor{} = kernel, %Axon{} = inp} ->
          {in_size, out_size} = Nx.shape(kernel)
          layer = Axon.embedding(inp, in_size, out_size, name: output_name)

          updated_params = Map.put(used_params, output_name, %{"kernel" => kernel})
          updated_axon = Map.put(axon, output_name, layer)
          {updated_axon, updated_params}

        {%Axon{op: :constant, opts: [value: x]}, %Axon{op: :constant, opts: [value: ind]}} ->
          new_value = Nx.take(x, Nx.as_type(ind, {:s, 64}))
          layer = Axon.constant(new_value, name: output_name)
          updated_axon = Map.put(axon, output_name, layer)
          {updated_axon, used_params}

        {%Nx.Tensor{} = x, %Nx.Tensor{} = ind} ->
          new_value = Nx.take(x, Nx.as_type(ind, {:s, 64}))
          # TODO: Should this be graph or param?
          layer = Axon.constant(new_value, name: output_name)
          updated_axon = Map.put(axon, output_name, layer)
          {updated_axon, used_params}

        {%Axon{} = x, %Axon{} = ind} ->
          axis = gather_options["axis"]
          layer = gather_layer(x, ind, axis, output_name)
          updated_axon = Map.put(axon, output_name, layer)
          {updated_axon, used_params}
      end

    {updated_axon, params, updated_params}
  end

  defp recur_nodes(
         %Node{op_type: "MatMul", input: [a, b], output: [output_name]},
         {axon, params, used_params}
       ) do
    a = input!(a, axon, params)
    b = input!(b, axon, params)

    # TODO: Constant folding
    {updated_axon, updated_params} =
      case {a, b} do
        {%Axon{} = inp, %Nx.Tensor{} = kernel} ->
          units = Nx.shape(kernel) |> elem(1)

          layer = Axon.dense(inp, units, name: output_name, use_bias: false)

          updated_axon = Map.put(axon, output_name, layer)
          updated_params = Map.put(used_params, output_name, %{"kernel" => kernel})
          {updated_axon, updated_params}

        {%Nx.Tensor{} = kernel, %Axon{} = inp} ->
          units = Nx.shape(kernel) |> elem(1)

          layer = Axon.dense(inp, units, name: output_name, use_bias: false)

          updated_axon = Map.put(axon, output_name, layer)
          updated_params = Map.put(used_params, output_name, %{"kernel" => kernel})
          {updated_axon, updated_params}

        {%Axon{} = a, %Axon{} = b} ->
          layer = numpy_matmul_layer(a, b, output_name)
          updated_axon = Map.put(axon, output_name, layer)
          {updated_axon, used_params}
      end

    {updated_axon, params, updated_params}
  end

  defp recur_nodes(
         %Node{op_type: "Gemm", input: [a, b | maybe_c], attribute: attrs, output: [output_name]},
         {axon, params, used_params}
       ) do
    gemm_options = options!(attrs)

    # TODO:
    # alpha = gemm_options["alpha"]
    # beta = gemm_options["beta"]
    trans_a = gemm_options["transA"]
    trans_b = gemm_options["transB"]

    a = input!(a, axon, params)
    b = input!(b, axon, params)

    {updated_axon, updated_params} =
      case {a, b} do
        {%Axon{output_shape: inp_shape} = inp, %Nx.Tensor{} = kernel} ->
          inp_perm = Enum.to_list((tuple_size(inp_shape) - 1)..0//-1)
          inp = if trans_a == 1, do: Axon.transpose(inp, inp_perm), else: inp
          kernel = if trans_b == 1, do: Nx.transpose(kernel), else: kernel

          units = Nx.shape(kernel) |> elem(1)
          use_bias = maybe_c != []

          layer = Axon.dense(inp, units, name: output_name, use_bias: use_bias)

          updated_axon = Map.put(axon, output_name, layer)

          updated_params =
            if use_bias do
              [c] = maybe_c
              bias = input!(c, axon, params)
              Map.put(used_params, output_name, %{"kernel" => kernel, "bias" => bias})
            else
              Map.put(used_params, output_name, %{"kernel" => kernel})
            end

          {updated_axon, updated_params}

        {%Nx.Tensor{} = kernel, %Axon{output_shape: inp_shape} = inp} ->
          inp_perm = Enum.to_list((tuple_size(inp_shape) - 1)..0//-1)
          inp = if trans_a == 1, do: Axon.transpose(inp, inp_perm), else: inp
          kernel = if trans_b == 1, do: Nx.transpose(kernel), else: kernel

          units = Nx.shape(kernel) |> elem(1)
          use_bias = maybe_c != []

          layer = Axon.dense(inp, units, name: output_name, use_bias: use_bias)

          updated_axon = Map.put(axon, output_name, layer)

          updated_params =
            if use_bias do
              [c] = maybe_c
              bias = input!(c, axon, params)
              Map.put(used_params, output_name, %{"kernel" => kernel, "bias" => bias})
            else
              Map.put(used_params, output_name, %{"kernel" => kernel})
            end

          {updated_axon, updated_params}

        {%Axon{output_shape: a_shape} = a, %Axon{output_shape: b_shape} = b} ->
          a_perm = Enum.to_list((Nx.rank(a_shape) - 1)..0//-1)
          b_perm = Enum.to_list((Nx.rank(b_shape) - 1)..0//-1)
          a = if trans_a == 1, do: Axon.transpose(a, a_perm), else: a
          b = if trans_b == 1, do: Axon.transpose(b, b_perm), else: b

          layer = numpy_matmul_layer(a, b, output_name)
          updated_axon = Map.put(axon, output_name, layer)
          {updated_axon, used_params}
      end

    {updated_axon, params, updated_params}
  end

  defp recur_nodes(
         %Node{op_type: "MaxPool", input: [inp], attribute: attrs, output: [output_name]},
         {axon, params, used_params}
       ) do
    max_pool_options = options!(attrs)

    kernel_shape = max_pool_options["kernel_shape"]
    ceil_mode = max_pool_options["ceil_mode"] || 0
    auto_pad = max_pool_options["auto_pad"] || "NOTSET"
    storage_order = max_pool_options["storage_order"]
    pads = max_pool_options["pads"]
    strides = max_pool_options["strides"]
    dilations = max_pool_options["dilations"]

    # Kernel size is a list of integers
    kernel_size = List.to_tuple(kernel_shape)

    # Axon only supports default ceil_mode right now
    if ceil_mode != 0 do
      raise ArgumentError,
            "invalid ceil_mode #{inspect(ceil_mode)}, Axon only supports" <>
              " ceil_mode of 0"
    end

    # Storage Order is not an Axon concern
    if storage_order do
      Logger.warning(
        "Storage order is not supported by Axon and is instead a backend-specific" <>
          " detail. Your model might behave differently from the imported version if" <>
          " the storage order differs"
      )
    end

    # Axon default strides are equal to the kernel shape (Keras behavior)
    # where as strides default to 1 in ONNX
    strides =
      if strides do
        strides
      else
        List.duplicate(1, tuple_size(kernel_size))
      end

    %Axon{output_shape: shape} = inp = axon!(inp, axon)

    # Compute padding from auto_pad and pads attributes
    padding_config = padding!(auto_pad, pads, shape, kernel_size, strides)

    updated_axon =
      Map.put(
        axon,
        output_name,
        Axon.max_pool(inp,
          kernel_size: kernel_size,
          strides: strides,
          padding: padding_config,
          dilations: dilations,
          name: output_name
        )
      )

    {updated_axon, params, used_params}
  end

  defp recur_nodes(
         %Node{op_type: "AveragePool", input: [inp], attribute: attrs, output: [output_name]},
         {axon, params, used_params}
       ) do
    avg_pool_options = options!(attrs)

    kernel_shape = avg_pool_options["kernel_shape"]
    ceil_mode = avg_pool_options["ceil_mode"] || 0
    auto_pad = avg_pool_options["auto_pad"] || "NOTSET"
    _count_include_pad = avg_pool_options["count_include_pad"] || 0
    pads = avg_pool_options["pads"]
    strides = avg_pool_options["strides"]
    dilations = avg_pool_options["dilations"]

    # Kernel size is a list of integers
    kernel_size = List.to_tuple(kernel_shape)

    # Axon only supports default ceil_mode right now
    if ceil_mode != 0 do
      raise ArgumentError,
            "invalid ceil_mode #{inspect(ceil_mode)}, Axon only supports" <>
              " ceil_mode of 0"
    end

    # Axon only supports count_include_pad == 1
    # if count_include_pad != 1 do
    #   raise ArgumentError, "invalid count_include_pad #{inspect(count_include_pad)}," <>
    #                           " Axon only supports mode 1"
    # end

    # Axon default strides are equal to the kernel shape (Keras behavior)
    # where as strides default to 1 in ONNX
    strides =
      if strides do
        strides
      else
        List.duplicate(1, tuple_size(kernel_size))
      end

    %Axon{output_shape: shape} = inp = axon!(inp, axon)

    # Compute padding from auto_pad and pads attributes
    padding_config = padding!(auto_pad, pads, shape, kernel_size, strides)

    updated_axon =
      Map.put(
        axon,
        output_name,
        Axon.avg_pool(inp,
          kernel_size: kernel_size,
          strides: strides,
          padding: padding_config,
          dilations: dilations,
          name: output_name
        )
      )

    {updated_axon, params, used_params}
  end

  defp recur_nodes(
         %Node{op_type: "Conv", attribute: attrs, input: input, output: [output_name]},
         {axon, params, used_params}
       ) do
    conv_options = options!(attrs)

    kernel_shape = conv_options["kernel_shape"]
    auto_pad = conv_options["auto_pad"] || "NOTSET"
    dilations = conv_options["dilations"]
    group = conv_options["group"]
    pads = conv_options["pads"]
    strides = conv_options["strides"]

    [inp, kernel | maybe_bias] = input

    # Kernel shape is a list of integers; If it's not present, infer it
    # from other values.
    kernel_size =
      if kernel_shape do
        List.to_tuple(kernel_shape)
      else
        Nx.shape(kernel)
        |> Tuple.delete_at(0)
        |> Tuple.delete_at(0)
      end

    %Axon{output_shape: shape} = axon_inp = axon!(inp, axon)

    padding_config = padding!(auto_pad, pads, shape, kernel_size, strides)

    kernel = param!(kernel, params)

    units = elem(Nx.shape(kernel), 0)

    updated_params =
      if maybe_bias == [] do
        Map.put(used_params, output_name, %{"kernel" => kernel})
      else
        [bias] = maybe_bias
        bias = param!(bias, params)
        Map.put(used_params, output_name, %{"kernel" => kernel, "bias" => bias})
      end

    updated_axon =
      Map.put(
        axon,
        output_name,
        Axon.conv(
          axon_inp,
          units,
          kernel_size: kernel_size,
          feature_group_size: group,
          kernel_dilation: dilations,
          padding: padding_config,
          strides: strides,
          use_bias: maybe_bias != [],
          name: output_name
        )
      )

    {updated_axon, params, updated_params}
  end

  defp recur_nodes(
         %Node{
           op_type: "BatchNormalization",
           input: [inp, gamma, beta, mean, var],
           output: [output_name],
           attribute: attrs
         },
         {axon, params, used_params}
       ) do
    options = options!(attrs)

    mode = options["training_mode"] || 0
    epsilon = options["epsilon"] || 1.0e-5
    momentum = options["momenutm"] || 0.9

    if mode == 1 do
      Logger.warn("Training mode in batch norm has no effect")
    end

    inp = axon!(inp, axon)

    gamma = param!(gamma, params)
    beta = param!(beta, params)
    mean = param!(mean, params)
    var = param!(var, params)

    updated_axon =
      Map.put(
        axon,
        output_name,
        Axon.batch_norm(inp, name: output_name, momentum: momentum, epsilon: epsilon)
      )

    updated_params =
      Map.put(used_params, output_name, %{
        "gamma" => gamma,
        "beta" => beta,
        "mean" => mean,
        "var" => var
      })

    {updated_axon, params, updated_params}
  end

  defp recur_nodes(
         %Node{op_type: "Concat", attribute: attrs, input: inputs, output: [output_name]},
         {axon, params, used_params}
       ) do
    inputs = for inp <- inputs, do: input!(inp, axon, params)
    %{"axis" => axis} = options!(attrs)

    updated_axon =
      if Enum.all?(inputs, &constant?/1) do
        vals = Enum.map(inputs, &get_value/1)
        new_value = Nx.concatenate(vals, axis: axis)
        Map.put(axon, output_name, Axon.constant(new_value, name: output_name))
      else
        Map.put(axon, output_name, Axon.concatenate(inputs, axis: axis, name: output_name))
      end

    {updated_axon, params, used_params}
  end

  # Builds an Axon layer which returns a new layer upsampling the input
  # layer. The scale activation layer must contain 1.0 as the first two values
  # Each dimension value of the output layer is:
  # output_dimension = floor(input_dimension * scale)
  defp recur_nodes(
         %Node{op_type: "Upsample", attribute: attrs, input: [inp, scale], output: [output_name]},
         {axon, params, used_params}
       ) do
    %Axon{output_shape: shape} = inp = axon!(inp, axon)
    %{"mode" => mode} = options!(attrs)
    scale = constant!(scale, axon, params)

    # Ignoring the first two 1.0 values to obtain the same dimension of scale_values
    [_, _ | shape] = Tuple.to_list(shape)

    # Converting mode from string to atom to ensure Axon init and predict works correctly
    method =
      cond do
        is_binary(mode) -> String.to_atom(mode)
        is_atom(mode) -> mode
        true -> raise ArgumentError, "unsupported mode type. Must be string or atom, got: #{mode}"
      end

    output_shape =
      case Nx.to_flat_list(scale) do
        [1.0, 1.0 | scale_values] ->
          scale_values
          |> Enum.zip_with(shape, fn x, y -> floor(x * y) end)
          |> List.to_tuple()

        [s1, s2 | _] ->
          raise ArgumentError,
                "unspported scale format, first two scale values must be 1, got #{s1} and #{s2}"
      end

    layer = Axon.resize(inp, output_shape, method: method, name: output_name)
    updated_axon = Map.put(axon, output_name, layer)

    {updated_axon, params, used_params}
  end

  defp recur_nodes(
         %Node{op_type: "Split", attribute: attrs, input: [inp], output: output_names},
         {axon, params, used_params}
       ) do
    inp = axon!(inp, axon)
    %{"axis" => axis, "split" => split_sizes} = options!(attrs)

    split_layers = Axon.split(inp, split_sizes, axis: axis, name: output_names)

    updated_axon =
      Enum.reduce(Tuple.to_list(split_layers), axon, fn output, new_axon ->
        Map.put(new_axon, output.name, output)
      end)

    {updated_axon, params, used_params}
  end

  defp recur_nodes(
         %Node{op_type: "Constant", attribute: attrs, output: [output_name]},
         {axon, params, used_params}
       ) do
    constant_options = options!(attrs)

    const =
      cond do
        constant_options["sparse_value"] ->
          raise ArgumentError, "sparse tensors are not supported"

        constant_options["value"] ->
          Axon.constant(tensor!(constant_options["value"]), name: output_name)

        constant_options["value_float"] ->
          Axon.constant(Nx.tensor(constant_options["value_float"], type: {:f, 32}),
            name: output_name
          )

        constant_options["value_floats"] ->
          Axon.constant(Nx.tensor(constant_options["value_floats"], type: {:f, 32}),
            name: output_name
          )

        constant_options["value_int"] ->
          Axon.constant(Nx.tensor(constant_options["value_int"], type: {:s, 64}),
            name: output_name
          )

        constant_options["value_ints"] ->
          Axon.constant(Nx.tensor(constant_options["value_ints"], type: {:s, 64}),
            name: output_name
          )

        constant_options["value_string"] or constant_options["value_strings"] ->
          raise ArgumentError, "string tensors are not supported"

        true ->
          raise ArgumentError, "invalid constant tensor type"
      end

    updated_axon = Map.put(axon, output_name, const)

    {updated_axon, params, used_params}
  end

  defp recur_nodes(
         %Node{
           op_type: "ConstantOfShape",
           attribute: attrs,
           input: [shape],
           output: [output_name]
         },
         {axon, params, used_params}
       ) do
    constant_options = options!(attrs)
    value = tensor!(constant_options["value"])

    shape =
      shape
      |> constant!(axon, params)
      |> Nx.to_flat_list()
      |> Enum.map(fn
        -1 -> 1
        x -> x
      end)
      |> List.to_tuple()

    val = Nx.broadcast(value, shape)

    updated_axon = Map.put(axon, output_name, Axon.constant(val, name: output_name))
    {updated_axon, params, used_params}
  end

  defp recur_nodes(
         %Node{op_type: "Reshape", input: [inp, shape], attribute: attrs, output: [output_name]},
         {axon, params, used_params}
       ) do
    reshape_options = options!(attrs)

    allowzero = reshape_options["allowzero"] || 0
    inp = axon!(inp, axon)

    # Reshape is a constant value input that MUST be known
    # ahead of time so we can build a static graph, we can't
    # support any other reshape types
    shape = constant!(shape, axon, params)

    # We currently do not support zero sized dimensions
    if allowzero == 1 do
      Logger.warning(
        "Nx does not support zero-sized dimensions. If your reshape" <>
          " operation contains a zero-sized dimension, it will fail"
      )
    end

    new_shape =
      shape
      |> Nx.to_flat_list()
      |> Enum.reduce({[], false}, fn
        -1, {cur_shape, false} -> {[:auto | cur_shape], true}
        -1, {cur_shape, true} -> {[1 | cur_shape], true}
        x, {cur_shape, already_auto?} -> {[x | cur_shape], already_auto?}
      end)
      |> elem(0)
      |> Enum.reverse()
      |> List.to_tuple()

    updated_axon =
      case inp do
        %Axon{op: :constant, opts: [value: v]} ->
          new_value = Nx.reshape(v, new_shape)
          Map.put(axon, output_name, Axon.constant(new_value, name: output_name))

        %Axon{} = inp ->
          Map.put(
            axon,
            output_name,
            Axon.reshape(inp, new_shape, name: output_name, ignore_batch?: false)
          )
      end

    {updated_axon, params, used_params}
  end

  defp recur_nodes(
         %Node{op_type: "Expand", input: [inp, shape], output: [output_name]},
         {axon, params, used_params}
       ) do
    inp = input!(inp, axon, params)
    shape = constant!(shape, axon, params)

    shape =
      shape
      |> Nx.to_flat_list()
      |> Enum.map(fn
        -1 -> 1
        x -> x
      end)
      |> List.to_tuple()

    updated_axon =
      case inp do
        %Axon{op: :constant, opts: [value: v]} ->
          new_value = Nx.multiply(v, Nx.broadcast(1, shape))
          layer = Axon.constant(new_value, name: output_name)
          updated_axon = Map.put(axon, output_name, layer)
          updated_axon

        %Nx.Tensor{} = x ->
          new_value = Nx.multiply(x, Nx.broadcast(1, shape))
          layer = Axon.constant(new_value, name: output_name)
          updated_axon = Map.put(axon, output_name, layer)
          updated_axon

        %Axon{} = inp ->
          fun = fn x, _params -> Nx.multiply(x, Nx.broadcast(1, shape)) end
          layer = Axon.layer([inp], fun, %{}, output_name, layer_op: :expand)
          updated_axon = Map.put(axon, output_name, layer)
          updated_axon
      end

    {updated_axon, params, used_params}
  end

  defp recur_nodes(
         %Node{op_type: "Range", input: [start, limit, delta], output: [output_name]},
         {axon, params, used_params}
       ) do
    start = constant!(start, axon, params) |> Nx.to_number()
    limit = constant!(limit, axon, params) |> Nx.to_number()
    delta = constant!(delta, axon, params) |> Nx.to_number()

    number_of_elements = max(ceil(div(limit - start, delta)), 0)

    vals =
      for i <- 0..(number_of_elements - 1) do
        start + i * delta
      end

    updated_axon = Map.put(axon, output_name, Axon.constant(Nx.tensor(vals), name: output_name))
    {updated_axon, params, used_params}
  end

  defp recur_nodes(
         %Node{op_type: "Flatten", input: [inp], output: [output_name]},
         {axon, params, used_params}
       ) do
    inp = axon!(inp, axon)

    {Map.put(axon, output_name, Axon.flatten(inp, name: output_name)), params, used_params}
  end

  defp recur_nodes(
         %Node{op_type: "Slice", input: [inp, starts, ends], output: [output_name]},
         {axon, params, used_params}
       ) do
    inp = input!(inp, axon, params)
    shape = get_shape(inp)
    rank = Nx.rank(shape)

    starts = constant!(starts, axon, params) |> Nx.to_flat_list()
    ends = constant!(ends, axon, params) |> Nx.to_flat_list()
    axes = Nx.axes(shape)
    steps = List.duplicate(1, rank)

    {updated_axon, updated_params} =
      slice_layer(inp, starts, ends, axes, steps, output_name, axon, used_params)

    {updated_axon, params, updated_params}
  end

  defp recur_nodes(
         %Node{op_type: "Slice", input: [inp, starts, ends, axes], output: [output_name]},
         {axon, params, used_params}
       ) do
    inp = input!(inp, axon, params)

    starts = constant!(starts, axon, params) |> Nx.to_flat_list()
    ends = constant!(ends, axon, params) |> Nx.to_flat_list()
    axes = constant!(axes, axon, params) |> Nx.to_flat_list()
    steps = List.duplicate(1, length(axes))

    {updated_axon, updated_params} =
      slice_layer(inp, starts, ends, axes, steps, output_name, axon, used_params)

    {updated_axon, params, updated_params}
  end

  defp recur_nodes(
         %Node{op_type: "Slice", input: [inp, starts, ends, axes, steps], output: [output_name]},
         {axon, params, used_params}
       ) do
    inp = input!(inp, axon, params)

    starts = constant!(starts, axon, params) |> Nx.to_flat_list()
    ends = constant!(ends, axon, params) |> Nx.to_flat_list()
    axes = constant!(axes, axon, params) |> Nx.to_flat_list()
    steps = constant!(steps, axon, params) |> Nx.to_flat_list()

    {updated_axon, updated_params} =
      slice_layer(inp, starts, ends, axes, steps, output_name, axon, used_params)

    {updated_axon, params, updated_params}
  end

  defp recur_nodes(
         %Node{op_type: "Shape", input: [inp], attribute: attrs, output: [output_name]},
         {axon, params, used_params}
       ) do
    shape_opts = options!(attrs)
    input = input!(inp, axon, params)
    shape = get_shape(input)
    rank = Nx.rank(shape)

    ends = shape_opts["end"]
    starts = shape_opts["start"] || 0
    starts = max(-rank, min(rank - 1, starts))
    start_axis = Nx.Shape.normalize_axis(shape, starts, List.duplicate(nil, rank))

    end_axis =
      if ends != nil and ends > -rank and ends < rank do
        ends = max(-rank + 1, min(rank - 1, ends))
        Nx.Shape.normalize_axis(shape, ends, List.duplicate(nil, rank))
      else
        rank
      end

    shape_list =
      for i <- start_axis..(end_axis - 1) do
        elem(shape, i) || -1
      end

    layer = Axon.constant(Nx.tensor(shape_list), name: output_name)
    updated_axon = Map.put(axon, output_name, layer)

    {updated_axon, params, used_params}
  end

  defp recur_nodes(
         %Node{op_type: "Transpose", input: [input], attribute: attrs, output: [output_name]},
         {axon, params, used_params}
       ) do
    transpose_options = options!(attrs)

    inp = input!(input, axon, params)

    {updated_axon, updated_params} =
      case inp do
        %Axon{output_shape: shape} = inp ->
          rank = Nx.rank(shape)
          permutation = transpose_options["perm"] || Enum.to_list((rank - 1)..0//-1)
          ignore_batch? = length(permutation) == tuple_size(shape) - 1

          layer =
            Axon.transpose(inp, permutation, name: output_name, ignore_batch?: ignore_batch?)

          updated_axon = Map.put(axon, output_name, layer)
          {updated_axon, used_params}

        %Nx.Tensor{} = inp ->
          rank = Nx.rank(inp)
          permutation = transpose_options["perm"] || Enum.to_list((rank - 1)..0//-1)
          new_value = Nx.transpose(inp, axes: permutation)
          updated_params = Map.replace(used_params, output_name, new_value)
          {axon, updated_params}
      end

    {updated_axon, params, updated_params}
  end

  defp recur_nodes(
         %Node{
           op_type: "Unsqueeze",
           input: [input | maybe_axis],
           attribute: attrs,
           output: [output_name]
         },
         {axon, params, used_params}
       ) do
    unsqueeze_options = options!(attrs)

    inp = axon!(input, axon)

    axes =
      case maybe_axis do
        [] ->
          unsqueeze_options["axes"]

        [axes] ->
          constant!(axes, axon, params) |> Nx.to_flat_list()
      end

    fun = fn input ->
      Enum.reduce(axes, input, fn axis, x -> Nx.new_axis(x, axis) end)
    end

    case inp do
      %Nx.Tensor{} = tensor ->
        updated_params = Map.put(used_params, output_name, fun.(tensor))
        {axon, params, updated_params}

      %Axon{op: :constant, opts: [value: tensor]} ->
        new_value = fun.(tensor)
        updated_axon = Map.put(axon, output_name, Axon.constant(new_value))
        {updated_axon, params, used_params}

      %Axon{} = model ->
        updated_axon = Map.put(axon, output_name, Axon.nx(model, fun, name: output_name))
        {updated_axon, params, used_params}
    end
  end

  defp recur_nodes(
         %Node{op_type: "If", input: [input], attribute: attrs, output: outputs},
         {axon, params, used_params}
       ) do
    cond_options = options!(attrs)

    inp = axon!(input, axon)

    else_branch = cond_options["else_branch"]
    then_branch = cond_options["then_branch"]

    # TODO: Don't match
    {[else_graph], else_params} = graph_to_axon(else_branch, [])
    {[then_graph], then_params} = graph_to_axon(then_branch, [])

    updated_axon =
      outputs
      |> Enum.reduce(axon, fn out_name, axon ->
        Map.put(axon, out_name, Axon.cond(inp, & &1, then_graph, else_graph))
      end)

    updated_params =
      else_params
      |> Map.merge(then_params)
      |> Map.merge(used_params)

    {updated_axon, params, updated_params}
  end

  defp recur_nodes(
         %Node{op_type: "Where", input: [c_name, x_name, y_name], output: [output_name]},
         {axon, params, used_params}
       ) do
    condition = input!(c_name, axon, params)
    x = input!(x_name, axon, params)
    y = input!(y_name, axon, params)

    {updated_axon, updated_params} =
      case {condition, x, y} do
        {%Axon{op: :constant, opts: [value: c]}, %Axon{op: :constant, opts: [value: x]},
         %Axon{op: :constant, opts: [value: y]}} ->
          new_value = Nx.select(c, x, y)
          updated_axon = Map.put(axon, output_name, Axon.constant(new_value, name: output_name))
          {updated_axon, used_params}

        {%Axon{} = condition, %Axon{} = x, %Axon{} = y} ->
          fun = fn x, y, z, _params -> Nx.select(x, y, z) end
          layer = Axon.layer([condition, x, y], fun, %{}, output_name, layer_op: :where)
          updated_axon = Map.put(axon, output_name, layer)
          {updated_axon, used_params}

        {%Axon{} = condition, %Axon{} = x, %Nx.Tensor{} = y} ->
          # TODO: Nx's shape rules should handle this like a binary broadcast
          # between all operands
          fun = fn x, y, params ->
            x = Nx.multiply(x, Nx.broadcast(1, y))
            y = Nx.multiply(y, Nx.broadcast(1, x))
            z = Nx.multiply(params[y_name], Nx.broadcast(1, y))
            Nx.select(x, y, z)
          end

          param = Axon.param(y_name, Nx.shape(y))

          layer =
            Axon.layer([condition, x], fun, %{y_name => param}, output_name, layer_op: :where)

          updated_axon = Map.put(axon, output_name, layer)
          updated_params = Map.put(used_params, output_name, %{y_name => param})
          {updated_axon, updated_params}
      end

    {updated_axon, params, updated_params}
  end

  defp recur_nodes(
         %Node{op_type: "CumSum", input: [x, axis], output: [output_name]},
         {axon, params, used_params}
       ) do
    x = axon!(x, axon)
    axis = constant!(axis, axon, params) |> Nx.to_number()

    fun = fn x ->
      n = elem(Nx.shape(x), axis)

      padding_config =
        for i <- 0..(Nx.rank(x) - 1) do
          if i == axis, do: {n - 1, 0}, else: {0, 0}
        end

      strides = List.duplicate(1, Nx.rank(x))

      window_shape =
        List.duplicate(1, Nx.rank(x))
        |> List.to_tuple()
        |> put_elem(axis, n)

      Nx.window_sum(x, window_shape, strides: strides, padding: padding_config)
    end

    updated_axon = Map.put(axon, output_name, Axon.nx(x, fun))
    {updated_axon, params, used_params}
  end

  defp recur_nodes(
         %Node{op_type: "Clip", input: [inp_name, min_name, max_name], output: [output_name]},
         {axon, params, used_params}
       ) do
    inp = input!(inp_name, axon, params)
    min = input!(min_name, axon, params)
    max = input!(max_name, axon, params)

    {updated_axon, updated_params} =
      case {inp, min, max} do
        {%Axon{} = inp, %Axon{} = min, %Axon{} = max} ->
          fun = fn x, y, z, _params -> Nx.clip(x, y, z) end
          layer = Axon.layer([inp, min, max], fun, %{}, output_name, layer_op: :clip)
          updated_axon = Map.put(axon, output_name, layer)
          {updated_axon, used_params}

        {%Axon{op: :constant, opts: [value: v]}, %Nx.Tensor{} = min, %Nx.Tensor{} = max} ->
          new_value = Nx.clip(v, min, max)
          layer = Axon.constant(new_value, name: output_name)
          updated_axon = Map.put(axon, output_name, layer)
          {updated_axon, used_params}

        {%Axon{} = inp, %Nx.Tensor{} = min, %Nx.Tensor{} = max} ->
          op = fn x, params -> Nx.clip(x, params["min"], params["max"]) end

          params = %{
            "min" => Axon.param(min_name, Nx.shape(min)),
            "max" => Axon.param(max_name, Nx.shape(max))
          }

          layer = Axon.layer(inp, op, params, output_name, layer_op: :clip)
          updated_axon = Map.put(axon, output_name, layer)
          updated_params = Map.put(used_params, output_name, %{min_name => min, max_name => max})
          {updated_axon, updated_params}
      end

    {updated_axon, params, updated_params}
  end

  defp recur_nodes(
         %Node{op_type: "Squeeze", input: [data], output: [output_name]},
         {axon, params, used_params}
       ) do
    inp = input!(data, axon, params)
    axes = Nx.axes(get_shape(inp))

    fun = fn x, _params ->
      Nx.squeeze(x, axes: axes)
    end

    updated_axon =
      case inp do
        %Axon{op: :constant, opts: [value: v]} ->
          new_value = Nx.squeeze(v, axes: axes)
          layer = Axon.constant(new_value, name: output_name)
          Map.put(axon, output_name, layer)

        %Axon{} = inp ->
          layer = Axon.layer(inp, fun, %{}, output_name, layer_op: :squeeze)
          Map.put(axon, output_name, layer)
      end

    {updated_axon, params, used_params}
  end

  defp recur_nodes(
         %Node{op_type: "Squeeze", input: [data, axes], output: [output_name]},
         {axon, params, used_params}
       ) do
    inp = input!(data, axon, params)
    axes = constant!(axes, axon, params) |> Nx.to_flat_list()

    fun = fn x, _params ->
      Nx.squeeze(x, axes: axes)
    end

    updated_axon =
      case inp do
        %Axon{op: :constant, opts: [value: v]} ->
          new_value = Nx.squeeze(v, axes: axes)
          layer = Axon.constant(new_value, name: output_name)
          Map.put(axon, output_name, layer)

        %Axon{} = inp ->
          layer = Axon.layer(inp, fun, %{}, output_name, layer_op: :squeeze)
          Map.put(axon, output_name, layer)
      end

    {updated_axon, params, used_params}
  end

  defp recur_nodes(
         %Node{op_type: "Split", input: [input, split], attribute: attrs, output: outputs},
         {axon, params, used_params}
       ) do
    split_options = options!(attrs)

    inp = input!(input, axon, params)
    split = constant!(split, axon, params) |> Nx.to_flat_list()

    axis = split_options["axis"]

    layers = Axon.split(inp, split, axis: axis, name: outputs)

    updated_axon =
      layers
      |> Tuple.to_list()
      |> Enum.zip(outputs)
      |> Enum.reduce(axon, fn {x, name}, acc -> Map.put(acc, name, x) end)

    {updated_axon, params, used_params}
  end

  defp recur_nodes(
         %Node{op_type: "EyeLike", input: [input], attribute: attrs, output: [output_name]},
         {axon, params, used_params}
       ) do
    eye_options = options!(attrs)

    inp = input!(input, axon, params)
    shape = get_shape(inp)

    type = if eye_options["dtype"], do: onnx_type_to_nx_type(eye_options["dtype"]), else: {:f, 32}

    layer = Axon.constant(Nx.eye(shape, type: type))

    updated_axon = Map.put(axon, output_name, layer)
    {updated_axon, params, used_params}
  end

  defp recur_nodes(
         %Node{op_type: "RandomUniform", attribute: attrs, output: [output_name]},
         {axon, params, used_params}
       ) do
    random_options = options!(attrs)

    dtype = random_options["dtype"] || 1
    high = random_options["high"] || 1.0
    low = random_options["low"] || 0.0
    # TODO: Seed
    # seed = random_options["seed"]
    shape = random_options["shape"]
    nx_type = onnx_type_to_nx_type(dtype)

    tensor = Nx.random_uniform(List.to_tuple(shape), low, high, type: nx_type)
    layer = Axon.constant(tensor, name: output_name)
    updated_axon = Map.put(axon, output_name, layer)

    {updated_axon, params, used_params}
  end

  defp recur_nodes(
         %Node{
           op_type: "RandomUniformLike",
           input: [input],
           attribute: attrs,
           output: [output_name]
         },
         {axon, params, used_params}
       ) do
    random_options = options!(attrs)

    inp = input!(input, axon, params)
    shape = get_shape(inp)

    dtype = random_options["dtype"] || 1
    high = random_options["high"] || 1.0
    low = random_options["low"] || 0.0
    # TODO: Seed
    # seed = random_options["seed"]
    nx_type = onnx_type_to_nx_type(dtype)

    tensor = Nx.random_uniform(shape, low, high, type: nx_type)
    layer = Axon.constant(tensor, name: output_name)
    updated_axon = Map.put(axon, output_name, layer)

    {updated_axon, params, used_params}
  end

  defp recur_nodes(
         %Node{op_type: "RandomNormal", attribute: attrs, output: [output_name]},
         {axon, params, used_params}
       ) do
    random_options = options!(attrs)

    dtype = random_options["dtype"] || 1
    mean = random_options["mean"] || 0.0
    scale = random_options["scale"] || 1.0
    # TODO: Seed
    # seed = random_options["seed"]
    shape = random_options["shape"]
    nx_type = onnx_type_to_nx_type(dtype)

    tensor = Nx.random_normal(List.to_tuple(shape), mean, scale, type: nx_type)
    layer = Axon.constant(tensor, name: output_name)
    updated_axon = Map.put(axon, output_name, layer)

    {updated_axon, params, used_params}
  end

  defp recur_nodes(
         %Node{
           op_type: "RandomNormalLike",
           input: [input],
           attribute: attrs,
           output: [output_name]
         },
         {axon, params, used_params}
       ) do
    random_options = options!(attrs)

    inp = input!(input, axon, params)
    shape = get_shape(inp)

    dtype = random_options["dtype"] || 1
    mean = random_options["mean"] || 0.0
    scale = random_options["scale"] || 1.0
    # TODO: Seed
    # seed = random_options["seed"]
    nx_type = onnx_type_to_nx_type(dtype)

    tensor = Nx.random_normal(shape, mean, scale, type: nx_type)
    layer = Axon.constant(tensor, name: output_name)
    updated_axon = Map.put(axon, output_name, layer)

    {updated_axon, params, used_params}
  end

  defp recur_nodes(%Node{op_type: unsupported}, _) do
    raise ArgumentError, "unsupported #{inspect(unsupported)}"
  end

  # TODO(seanmor5): Handle segments
  def tensor!(%Tensor{data_type: dtype, dims: dims} = tensor) do
    shape = List.to_tuple(dims)

    case dtype do
      1 ->
        to_nx_tensor(tensor.float_data, tensor.raw_data, {:f, 32}, shape)

      2 ->
        to_nx_tensor(tensor.int32_data, tensor.raw_data, {:u, 8}, shape)

      3 ->
        to_nx_tensor(tensor.int32_data, tensor.raw_data, {:s, 8}, shape)

      4 ->
        to_nx_tensor(tensor.int32_data, tensor.raw_data, {:u, 16}, shape)

      5 ->
        to_nx_tensor(tensor.int32_data, tensor.raw_data, {:s, 16}, shape)

      6 ->
        to_nx_tensor(tensor.int32_data, tensor.raw_data, {:s, 32}, shape)

      7 ->
        to_nx_tensor(tensor.int64_data, tensor.raw_data, {:s, 64}, shape)

      8 ->
        raise "unsupported Nx tensor type: string"

      9 ->
        to_nx_tensor(tensor.int32_data, tensor.raw_data, {:u, 8}, shape)

      10 ->
        to_nx_tensor(tensor.int32_data, tensor.raw_data, {:f, 16}, shape)

      11 ->
        to_nx_tensor(tensor.double_data, tensor.raw_data, {:f, 64}, shape)

      12 ->
        to_nx_tensor(tensor.uint64_data, tensor.raw_data, {:u, 32}, shape)

      13 ->
        to_nx_tensor(tensor.uint64_data, tensor.raw_data, {:u, 64}, shape)

      14 ->
        # TODO(seanmor5): When complex is supported, tensor.float_data
        raise "unsupported Nx tensor type: C64"

      15 ->
        # TODO(seanmor5): When complex is supported, tensor.double_data
        raise "unsupported Nx tensor type: C128"

      16 ->
        to_nx_tensor([], tensor.raw_data, {:bf, 16}, shape)
    end
  end

  defp to_nx_tensor([], <<>>, _, _) do
    raise "unsupported empty Nx tensor"
  end

  defp to_nx_tensor([], raw, type, shape) do
    raw
    |> Nx.from_binary(type)
    |> Nx.reshape(shape)
  end

  defp to_nx_tensor(data, _, type, shape) do
    data
    |> Nx.tensor(type: type)
    |> Nx.reshape(shape)
  end

  defp axon!(name, axon) do
    if Map.has_key?(axon, name) do
      axon[name]
    else
      raise ArgumentError,
            "unable to build model from ONNX graph, expected value #{name}" <>
              " to be a graph input, but it was not present in built" <>
              " graphs"
    end
  end

  defp param!(name, params) do
    if Map.has_key?(params, name) do
      params[name]
    else
      raise ArgumentError,
            "unable to build model from ONNX graph, expected value #{name}" <>
              " to be a parameter input, but it was not present in" <>
              " initializers"
    end
  end

  defp input!(name, axon, params) do
    cond do
      Map.has_key?(axon, name) ->
        axon[name]

      Map.has_key?(params, name) ->
        params[name]

      true ->
        raise ArgumentError, "#{name} was not present in graph or initializers"
    end
  end

  defp constant!(name, axon, params) do
    cond do
      Map.has_key?(axon, name) ->
        case axon[name] do
          %Axon{op: :constant, opts: [value: shape]} ->
            shape

          %Axon{op: op} ->
            raise ArgumentError,
                  "unable to build model from ONNX graph, expected value #{name}" <>
                    " to be constant value, but was #{inspect(op)}"
        end

      Map.has_key?(params, name) ->
        params[name]

      true ->
        raise ArgumentError,
              "unable to build model from ONNX graph, could not find constant" <>
                " value #{name} in subgraphs or parameters"
    end
  end

  defp padding!(auto_pad, pads, shape, kernel_size, strides) do
    case auto_pad do
      val when val == "NOTSET" or val == nil ->
        case pads do
          pads when is_list(pads) ->
            pads
            |> Enum.count()
            |> then(&Enum.chunk_every(pads, div(&1, 2)))
            |> Enum.zip()

          nil ->
            :valid
        end

      val when val == "SAME_UPPER" ->
        :same

      val when val == "SAME_LOWER" ->
        Enum.zip_with([Tuple.to_list(shape), Tuple.to_list(kernel_size), strides], fn [dim, k, s] ->
          padding_size = max((dim - 1) * s + k - dim, 0)
          hi = floor(padding_size / 2)
          lo = ceil(padding_size / 2)
          {lo, hi}
        end)

      "VALID" ->
        :valid
    end
  end

  defp options!(attrs) when is_list(attrs) do
    Enum.reduce(attrs, %{}, fn %Attribute{type: type, name: name} = attr, options ->
      case type do
        :FLOAT ->
          Map.put(options, name, attr.f)

        :INT ->
          Map.put(options, name, attr.i)

        :STRING ->
          Map.put(options, name, attr.s)

        :TENSOR ->
          Map.put(options, name, attr.t)

        :GRAPH ->
          Map.put(options, name, attr.g)

        :SPARSE_TENSOR ->
          Map.put(options, name, attr.sparse_tensor)

        :TYPE_PROTO ->
          Map.put(options, name, attr.tp)

        :FLOATS ->
          Map.put(options, name, attr.floats)

        :INTS ->
          Map.put(options, name, attr.ints)

        :STRINGS ->
          Map.put(options, name, attr.strings)

        :TENSORS ->
          Map.put(options, name, attr.tensors)

        :GRAPHS ->
          Map.put(options, name, attr.graphs)

        :SPARSE_TENSORS ->
          Map.put(options, name, attr.sparse_tensors)

        :TYPE_PROTOS ->
          Map.put(options, name, attr.type_protos)
      end
    end)
  end

  defp shape!(%Placeholder{shape: %Shape{dim: dims}}, dim_params) do
    dims
    |> Enum.map(fn %Dimension{value: value} ->
      case value do
        {:dim_value, val} ->
          val

        {:dim_param, key} ->
          param = Keyword.get(dim_params, String.to_atom(key))

          unless param do
            Logger.warn("#{key} has no specified dimension, assuming nil")
          end

          param

        _ ->
          raise ArgumentError, "unsupported dimension type"
      end
    end)
    |> List.to_tuple()
  end
end
