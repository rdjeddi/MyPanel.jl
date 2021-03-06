#=##############################################################################
# DESCRIPTION
    Lifting paneled body types definition. Implementations of
    AbstractLiftingBody.
# AUTHORSHIP
  * Author    : Eduardo J. Alvarez
  * Email     : Edo.AlvarezR@gmail.com
  * Created   : Sep 2018
  * License   : AGPL-3.0
=###############################################################################



################################################################################
# RIGID-WAKE BODY TYPE
################################################################################
"""
  `RigidWakeBody(grid::gt.GridTriangleSurface)`

Lifting paneled body that is solved using a vortex-ring panels, and a steady,
rigid wake. `grid` is the grid surface (paneled geometry).

  **Properties**
  * `nnodes::Int64`                     : Number of nodes
  * `ncells::Int64`                     : Number of cells
  * `fields::Array{String, 1}`          : Available fields (solutions)
  * `Oaxis::Array{T,2} where {T<:Real}` : Coordinate system of original grid
  * `O::Array{T,1} where {T<:Real}`     : Position of CS of original grid
  * `ncellsTE::Int64`                   : Number of cells along trailing edge
  * `nnodesTE::Int64`                   : Number of nodes along trailing edge

"""
struct RigidWakeBody <: AbstractLiftingBody

  # User inputs
  grid::gt.GridTriangleSurface              # Paneled geometry
  U::Array{Int64,1}                         # Indices of all panels along the
                                            # upper side of the trailing edge
  L::Array{Int64,1}                         # Indices of all panels along the
                                            # lower side of the trailing edge

  # Properties
  nnodes::Int64                             # Number of nodes
  ncells::Int64                             # Number of cells
  fields::Array{String, 1}                  # Available fields (solutions)
  Oaxis::Array{T1,2} where {T1<:RType}      # Coordinate system of original grid
  O::Array{T2,1} where {T2<:RType}          # Position of CS of original grid
  ncellsTE::Int64                           # Number of cells along TE
  nnodesTE::Int64                           # Number of nodes along TE

  # Internal variables
  _G::Array{T3,2} where {T3<:RType}         # Body Geometry solution matrix
                                            # (it doesn't include the wake)

  RigidWakeBody(  grid,
                    U, L,
                  nnodes=grid.nnodes, ncells=grid.ncells,
                    fields=Array{String,1}(),
                    Oaxis=eye(3), O=zeros(3),
                    ncellsTE=size(U,1), nnodesTE=size(U,1)+1,
                  _G=_calc_G_lifting_vortexring(grid, U, L)
         ) = _checkTE(U,L) ? new( grid,
                    U, L,
                  nnodes, ncells,
                    fields,
                    Oaxis, O,
                    ncellsTE, nnodesTE,
                  _G
         ) : error("Got invalid trailing edge.")
end

function solve(self::RigidWakeBody, Vinfs::Array{Array{T1,1},1},
                          D::Array{Array{T2,1},1}) where {T1<:RType, T2<:RType}
  # ERROR CASES
  if size(Vinfs,1) != self.ncells
    error("Invalid Vinfs; expected size $(self.ncells), got $(size(Vinfs,1))")
  elseif size(D,1) != self.nnodesTE
    error("Invalid D; expected size $(self.nnodesTE), got $(size(D,1))")
  end

  CPs = [get_controlpoint(self, i) for i in 1:self.ncells] # Control points
  normals = [get_normal(self, i) for i in 1:self.ncells]

  # Geometric matrix --- Body contribution
  G = deepcopy(self._G)

  # Geometric matrix --- Rigid wake contribution
  for (j, u_j) in enumerate(self.U) # Iterates over upper side of TE

    # Upper in-going vortex
    PanelSolver.Vsemiinfinitevortex(
                          get_TE(self, j+1; upper=true),    # Starting point
                          D[j+1],                           # Direction
                          -1.0,                             # Unitary strength
                          CPs,                              # Targets
                                        # Velocity of j-th horseshoe on every CP
                          view(G, :, u_j);
                          dot_with=normals                  # Normal of every CP
                        )

    # Upper out-going vortex
    PanelSolver.Vsemiinfinitevortex(
                          get_TE(self, j; upper=true),      # Starting point
                          D[j],                             # Direction
                          1.0,                              # Unitary strength
                          CPs,                              # Targets
                                        # Velocity of j-th horseshoe on every CP
                          view(G, :, u_j);
                          dot_with=normals                  # Normal of every CP
                        )
  end

  for (j, l_j) in enumerate(self.L) # Iterates over lower side of TE

    # Incoming vortex
    PanelSolver.Vsemiinfinitevortex(
                          get_TE(self, j; upper=false), # Starting point
                          D[j],                         # Direction
                          -1.0,                         # Unitary strength
                          CPs,                          # Targets
                                      # Velocity of j-th horseshoe on every CP
                          view(G, :, l_j);
                          dot_with=normals              # Normal of every CP
                        )

    # Outgoing vortex
    PanelSolver.Vsemiinfinitevortex(
                          get_TE(self, j+1; upper=false), # Starting point
                          D[j+1],                         # Direction
                          1.0,                          # Unitary strength
                          CPs,                          # Targets
                                        # Velocity of j-th horseshoe on every CP
                          view(G, :, l_j);
                          dot_with=normals              # Normal of every CP
                        )
  end

  lambda = [-dot(Vinfs[i], get_normal(self, i)) for i in 1:self.ncells]
  Gamma = G\lambda

  # Gammas of upper and lower TE cells
  Gup = [Gamma[i] for i in self.U]
  Glo = [Gamma[i] for i in self.L]

  # Gamma at every TE bound vortex
  GTE = Glo - Gup

  # Gammas of the semi-infinite vortices
  # NOTE: Here I assume that all TE cells are contiguous
  Gammawake = vcat(GTE[1], [GTE[i]-GTE[i-1] for i in 2:self.nnodesTE-1], -GTE[end])

  add_field(self, "D", D)
  add_field(self, "Vinf", Vinfs)
  add_field(self, "Gamma", Gamma)
  add_field(self, "Gammawake", Gammawake)
  _solvedflag(self, true)
end



##### INTERNAL FUNCTIONS  ######################################################
"""
Returns the velocity induced by the body on the targets `targets`. It adds the
velocity at the i-th target to out[i].
"""
function _Vind(self::RigidWakeBody, targets::Array{Array{T1,1},1},
                          out::Array{Array{T2,1},1}) where{T1<:RType, T2<:RType}
  error("Not implemented yet.")
end

"""
Outputs a vtk file with the wake.
"""
function _savewake(self::RigidWakeBody, filename::String;
                    len::RType=1.0, upper::Bool=true, suffix="_wake",optargs...)

  if check_field(self, "D")==false
    error("Requested to save wake, but D field wasn't found.")
  end

  # Points along trailing edge
  TE = [get_TE(self, i; upper=upper) for i in 1:self.nnodesTE]

  # End point of wake
  wake = TE + len*get_field(self, "D")["field_data"]

  # Points and lines
  points = vcat(TE, wake)
  lines = [[i, i+self.nnodesTE] for i in 0:self.nnodesTE-1]

  # Point data
  point_data = []
  if check_solved(self)
    push!(point_data, Dict( "field_name"=> "Gamma",
                            "field_type"=> "scalar",
                            "field_data"=> vcat(
                                  get_field(self, "Gammawake")["field_data"],
                                  get_field(self, "Gammawake")["field_data"])))
  end

  # Generate VTK
  gt.generateVTK(filename*suffix, points; lines=lines, point_data=point_data,
                                                                    optargs...)
end
##### END OF RIGID-WAKE BODY ###################################################
