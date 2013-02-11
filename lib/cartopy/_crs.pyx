# (C) British Crown Copyright 2011 - 2012, Met Office
#
# This file is part of cartopy.
#
# cartopy is free software: you can redistribute it and/or modify it under
# the terms of the GNU Lesser General Public License as published by the
# Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# cartopy is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with cartopy.  If not, see <http://www.gnu.org/licenses/>.

"""
This module defines the core CRS class which can interface with Proj.4.
The CRS class is the base-class for all projections defined in :mod:`cartopy.crs`.

"""

import numpy as np

cimport numpy as np

from cython.operator cimport dereference as deref


cdef extern from "proj_api.h":
    ctypedef void *projPJ
    projPJ pj_init_plus(char *)
    void pj_free(projPJ)
    int pj_transform(projPJ, projPJ, long, int, double *, double *, double *)
    int pj_is_latlong(projPJ)
    char *pj_strerrno(int)
    int *pj_get_errno_ref()
    char *pj_get_release()
    double DEG_TO_RAD
    double RAD_TO_DEG


cdef double NAN = float('nan')

PROJ4_RELEASE = pj_get_release()

class Proj4Error(Exception):
    """
    Raised when there has been an exception calling proj.4.

    Adds a ``status`` attribute to the exception which has the
    proj.4 error reference.

    """
    def __init__(self):
        cdef int status
        status = deref(pj_get_errno_ref())
        msg = 'Error from proj.4: {}'.format(pj_strerrno(status))
        self.status = status
        Exception.__init__(self, msg)


cdef class CRS:
    """
    Defines a Coordinate Reference System using proj.4.

    """
    def __init__(self, proj4_params):
        """
        Args:

            * proj4_params - a dictionary of proj4 valid parameters
                             required to define the desired CRS.

        """
        self.proj4_params = dict(proj4_params)
        # Use WGS84 ellipse if one is not specified in proj4_params
        if 'ellps' not in self.proj4_params:
            self.proj4_params['ellps'] = 'WGS84'
        init_items = ['+{}={}'.format(k, v) for
                      k, v in self.proj4_params.iteritems()]
        self.proj4_init = ' '.join(sorted(init_items))
        self.proj4 = pj_init_plus(self.proj4_init)
        if not self.proj4:
            raise Proj4Error()

    # Cython uses this method instead of the normal rich comparisons.
    def __richcmp__(self, other, op):
        # We're only interested in:
        #   == -> 2
        #   != -> 3
        result = NotImplemented
        if isinstance(other, CRS):
            if op == 2:
                result = self.proj4_init == other.proj4_init
            elif op == 3:
                result = self.proj4_init != other.proj4_init
        return result

    def __reduce__(self):
        """
        Implements the __reduce__ API so that unpickling produces a stateless
        instance of this class (e.g. an empty tuple). The state will then be
        added via __getstate__ and __setstate__.
        """
        return self.__class__, tuple()
    
    def __getstate__(self):
        """Returns the full state of this instance for reconstruction in ``__setstate__``."""
        return {'proj4_params': self.proj4_params}
    
    def __setstate__(self, state):
        """
        Takes the dictionary created by ``__getstate__`` and passes it through to the
        class's __init__ method.
        """
        self.__init__(self, **state)
    
    # TODO
    #def __str__
    #def _geod(self): # to return the pyproj.Geod

    def __hash__(self):
        """Hashes the CRS based on its class and proj4_init string."""
        return hash((type(self), self.proj4_init))

    def _as_mpl_transform(self, axes=None):
        """
        Casts this CRS instance into a :class:`matplotlib.axes.Axes` using
        the matplotlib ``_as_mpl_transform`` interface.

        """
        # lazy import mpl.geoaxes (and therefore matplotlib) as mpl
        # is only an optional dependency
        import cartopy.mpl.geoaxes as geoaxes
        if not isinstance(axes, geoaxes.GeoAxes):
            raise ValueError('Axes should be an instance of GeoAxes, got %s' % type(axes))
        return geoaxes.InterProjectionTransform(self, axes.projection) + axes.transData

    property proj4_params:
        def __get__(self):
            return dict(self.proj4_params)

    def as_geocentric(self):
        """
        Returns a new Geocentric CRS with the same ellipse/datum as this
        CRS.

        """
        params = self.proj4_params
        keywords = {}
        for param_name, keyword in {'ellps': 'ellipse', 'datum': 'datum'}.iteritems():
            if param_name in params:
                keywords[keyword] = params[param_name]
        return Geocentric(**keywords)

    def as_geodetic(self):
        """
        Returns a new Geodetic CRS with the same ellipse/datum as this
        CRS.

        """
        params = self.proj4_params
        keywords = {}
        for param_name, keyword in {'ellps': 'ellipse', 'datum': 'datum'}.iteritems():
            if param_name in params:
                keywords[keyword] = params[param_name]
        return Geodetic(**keywords)

    cpdef is_geodetic(self):
        return bool(pj_is_latlong(self.proj4))

    def transform_point(self, double x, double y, CRS src_crs not None):
        """
        Transform the given float64 coordinate pair, in the given source
        coordinate system (``src_crs``), to this coordinate system.

        Args:

        * x - the x coordinate, in ``src_crs`` coordinates, to transform
        * y - the y coordinate, in ``src_crs`` coordinates, to transform
        * src_crs - instance of :class:`CRS` that represents the coordinate
                    system of ``x`` and ``y``.

        Returns:

            (x, y) - in this coordinate system

        .. seealso:: :meth:`transform_points`

        """
        cdef:
            double cx, cy
            int status
        cx = x
        cy = y
        if src_crs.is_geodetic():
            cx *= DEG_TO_RAD
            cy *= DEG_TO_RAD
        status = pj_transform(src_crs.proj4, self.proj4, 1, 1, &cx, &cy, NULL);
        #if status == -14 or status == -20:
            # -14 => "latitude or longitude exceeded limits"
            # -20 => "tolerance condition error"
        #    cx = cy = NAN
        #elif status != 0:
        #    raise Proj4Error()
        if self.is_geodetic():
            cx *= RAD_TO_DEG
            cy *= RAD_TO_DEG
        return (cx, cy)

    def transform_points(self, CRS src_crs not None, 
                                np.ndarray x not None, 
                                np.ndarray y not None, 
                                np.ndarray z=None):
        """
        Transform the given coordinates, in the given source
        coordinate system (``src_crs``), to this coordinate system.

        Args:

        * src_crs - instance of :class:`CRS` that represents the coordinate
                    system of ``x``, ``y`` and ``z``.
        * x - the x coordinates (array), in ``src_crs`` coordinates,
              to transform.  May be 1 or 2 dimensions.
        * y - the y coordinates (array), in ``src_crs`` coordinates,
              to transform
        * z - (optional) the z coordinates (array), in ``src_crs``
              coordinates, to transform.  Not applicable for projections.

        Returns:
           Array of shape ``x.shape + (3, )`` in this coordinate system.

        """
        cdef np.ndarray[np.double_t, ndim=2] result
        
        result_shape = tuple(x.shape[i] for i in range(x.ndim)) + (3, )
        
        if z is None:
            if x.ndim > 2 or y.ndim > 2:
                raise ValueError('x and y arrays must be 1 or 2 dimensional')
            elif x.ndim != 1 or y.ndim != 1:
                x, y = x.flatten(), y.flatten()

            if x.shape[0] != y.shape[0]:
                raise ValueError('x and y arrays must have the same length')
        else:
            if x.ndim > 2 or y.ndim > 2 or z.ndim > 2:
                raise ValueError('x, y and z arrays must be 1 or 2'
                                  'dimensional')
            elif x.ndim != 1 or y.ndim != 1 or z.ndim != 1:
                x, y, z = x.flatten(), y.flatten(), z.flatten()

            if not x.shape[0] == y.shape[0] == z.shape[0]:
                raise ValueError('x, y, and z arrays must have the same'
                                 'length')

        npts = x.shape[0]

        result = np.empty([npts, 3], dtype=np.double)
        result[:, 0] = x
        result[:, 1] = y
        # if a z has been given, put it in the result array which will be
        # transformed in-place
        if z is None:
            result[:, 2] = 0
        else:
            result[:, 2] = z

        if src_crs.is_geodetic():
            result = np.deg2rad(result)

        # call proj.4. The result array is modified in place.
        status = pj_transform(src_crs.proj4, self.proj4, npts, 3,
                              &result[0, 0], &result[0, 1], &result[0, 2]);
                              
        if self.is_geodetic():
            result = np.rad2deg(result)
        #if status:
        #    raise Proj4Error()

        if len(result_shape) > 2:
            transpose_order = tuple(range(result.ndim)[::-1]) + (2, )
            return result.reshape(result_shape).transpose(transpose_order)

        return result


class Geodetic(CRS):
    """
    Defines a latitude/longitude coordinate system with spherical topology,
    geographical distance and coordinates are measured in degrees.

    """
    # XXX Providing a default datum is bad. Providing the ellipse on its own is sufficient to define the ellipse, 
    # and in some cases, can overwrite the desired, well defined ellipse.
    def __init__(self, ellipse='WGS84', datum='WGS84'):
        """
        Kwargs:
        
            * ellipse - a proj.4 ellipsoid definition, default is 'WGS84'.
            * datum - a proj.4 datum definition, default is 'WGS84'.
        
        """
        proj4_params = {'proj': 'lonlat', 'ellps': ellipse, 'datum': datum}
        super(Geodetic, self).__init__(proj4_params)        
        
    # XXX Implement fwd such as Basemap's Geod. Would be used in the tissot example.
    # Could come from http://geographiclib.sourceforge.net
      

class Geocentric(CRS):
    """
    Defines a Geocentric coordinate system, where x, y, z are Cartesian
    coordinates from the center of the Earth.
    
    """
    def __init__(self, ellipse='WGS84', datum='WGS84'):
        """
        Kwargs:

            * ellipse - a proj.4 ellipsoid definition, default is 'WGS84'.
            * datum - a proj.4 datum definition, default is 'WGS84'.

        """
        proj4_params = {'proj': 'geocent', 'ellps': ellipse, 'datum': datum}
        super(Geocentric, self).__init__(proj4_params)
