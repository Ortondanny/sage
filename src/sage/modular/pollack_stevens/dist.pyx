# -*- coding: utf-8 -*-
"""
`p`-adic distributions spaces

This module implements p-adic distributions, a p-adic Banach
space dual to locally analytic functions on a disc.

EXAMPLES::

    sage: D = OverconvergentDistributions(5, 7, 15)
    sage: v = D([7,14,21,28,35]); v
    (7 + O(7^5), 2*7 + O(7^4), 3*7 + O(7^3), 4*7 + O(7^2), O(7))
"""

#*****************************************************************************
#       Copyright (C) 2012 Robert Pollack <rpollack@math.bu.edu>
#
#  Distributed under the terms of the GNU General Public License (GPL)
#  as published by the Free Software Foundation; either version 2 of
#  the License, or (at your option) any later version.
#                  http://www.gnu.org/licenses/
#*****************************************************************************
from __future__ import print_function
from sage.structure.sage_object import SageObject
from sage.rings.integer_ring import ZZ
from sage.rings.rational_field import QQ
from sage.rings.power_series_ring import PowerSeriesRing
from sage.rings.finite_rings.integer_mod_ring import Zmod
from sage.arith.all import binomial, bernoulli
from sage.modules.free_module_element import vector, zero_vector
from sage.matrix.matrix cimport Matrix
from sage.matrix.matrix_space import MatrixSpace
from sage.matrix.all import matrix
from sage.misc.prandom import random
from sage.functions.other import floor
from sage.structure.element cimport RingElement, Element
import operator
from sage.rings.padics.padic_generic import pAdicGeneric
from sage.rings.padics.padic_capped_absolute_element cimport pAdicCappedAbsoluteElement
from sage.rings.padics.padic_capped_relative_element cimport pAdicCappedRelativeElement
from sage.rings.padics.padic_fixed_mod_element cimport pAdicFixedModElement
from sage.rings.integer cimport Integer
from sage.rings.rational cimport Rational
from sage.misc.misc import verbose, cputime
from sage.rings.infinity import Infinity

include "sage/ext/cdefs.pxi"
include "cysignals/signals.pxi"
include "sage/ext/stdsage.pxi"

from sage.libs.flint.nmod_poly cimport (nmod_poly_init2_preinv,
                                        nmod_poly_set_coeff_ui,
                                        nmod_poly_inv_series,
                                        nmod_poly_mullow,
                                        nmod_poly_pow_trunc,
                                        nmod_poly_get_coeff_ui, nmod_poly_t)

#from sage.libs.flint.ulong_extras cimport *

from sigma0 import Sigma0

cdef long overflow = 1 << (4 * sizeof(long) - 1)
cdef long underflow = -overflow
cdef long maxordp = (1L << (sizeof(long) * 8 - 2)) - 1


def get_dist_classes(p, prec_cap, base, symk, implementation):
    r"""
    Determine the element and action classes to be used for given inputs.

    INPUT:

    - ``p``        -- prime

    - ``prec_cap`` -- The `p`-adic precision cap

    - ``base``     -- The base ring

    - ``symk``     -- An element of Symk

    - ``implementation`` - string - If not None, override the
      automatic choice of implementation. May be 'long' or 'vector',
      otherwise raise a ``NotImplementedError``

    OUTPUT:

    - Either a Dist_vector and WeightKAction_vector, or a Dist_vector_long
      and WeightKAction_vector_long

    EXAMPLES::

        sage: D = OverconvergentDistributions(2, 3, 5); D # indirect doctest
        Space of 3-adic distributions with k=2 action and precision cap 5
    """
    if implementation is not None:
        if implementation == 'long':
            raise NotImplementedError('The optimized implementation -using longs- has been disabled and may return wrong results.')
            #if base.is_field():
            #    raise NotImplementedError('The implementation "long" does'
            #                              ' not support fields as base rings')
            #if (isinstance(base, pAdicGeneric) and base.degree() > 1):
            #    raise NotImplementedError('The implementation "long" does not '
            #                              'support extensions of p-adics')
            #if p is None:
            #    raise NotImplementedError('The implementation "long" supports'
            #                              ' only p-adic rings')
            #return Dist_long, WeightKAction_long
        elif implementation == 'vector':
            return Dist_vector, WeightKAction_vector
        else:
            raise NotImplementedError('The implementation "%s" does not exist yet' % (implementation))

    return Dist_vector, WeightKAction_vector
    # We return always the "slow" (but safe) implementation.
    # if symk or p is None or base.is_field() or (isinstance(base, pAdicGeneric) and base.degree() > 1):
    #     return Dist_vector, WeightKAction_vector
    # if 7 * p ** (prec_cap) < ZZ(2) ** (4 * sizeof(long) - 1):
    #     return Dist_long, WeightKAction_long
    # else:
    #     return Dist_vector, WeightKAction_vector


cdef class Dist(ModuleElement):
    r"""
        The main `p`-adic distribution class, implemented as per the paper
        'Overconvergent Modular Symbols and p-adic L-functions' by Pollack
        & Stevens
    """ ## mm TODO reference
    def moment(self, n):
        r"""
        Return the `n`-th moment.

        INPUT:

        - ``n`` -- an integer or slice, to be passed on to moments.

        OUTPUT:

        - the `n`-th moment, or a list of moments in the case that `n`
          is a slice.

        EXAMPLES::

            sage: D = OverconvergentDistributions(4, 7, 10)
            sage: v = D([7,14,21,28,35]);
            sage: v.moment(3)
            4*7 + O(7^2)
            sage: v.moment(0)
            7 + O(7^5)
        """
        return self.parent().prime() ** (self.ordp) * self._unscaled_moment(n)

    def moments(self):
        r"""
        Return the vector of moments.

        OUTPUT:

        - the vector of moments

        EXAMPLES::

            sage: D = OverconvergentDistributions(4, 5, 10, base = Qp(5));
            sage: v = D([1,7,4,2,-1])
            sage: v = 1/5^3 * v
            sage: v
            5^-3 * (1 + O(5^5), 2 + 5 + O(5^4), 4 + O(5^3), 2 + O(5^2), 4 + O(5))
            sage: v.moments()
            (5^-3 + O(5^2), 2*5^-3 + 5^-2 + O(5), 4*5^-3 + O(5^0), 2*5^-3 + O(5^-1), 4*5^-3 + O(5^-2))
        """
        return self.parent().prime() ** (self.ordp) * self._moments

    cpdef normalize(self):
        r"""
        Normalize so that the precision of the `i`-th moment is `n-i`,
        where `n` is the number of moments.

        OUTPUT:

        - Normalized entries of the distribution

        EXAMPLES::

            sage: D = OverconvergentDistributions(5, 7, 15); D
            Space of 7-adic distributions with k=5 action and precision cap 15
            sage: v = D([1,2,3,4,5]); v
            (1 + O(7^5), 2 + O(7^4), 3 + O(7^3), 4 + O(7^2), 5 + O(7))
            sage: v.normalize()
            (1 + O(7^5), 2 + O(7^4), 3 + O(7^3), 4 + O(7^2), 5 + O(7))
        """
        raise NotImplementedError

    cdef long _relprec(self):
        raise NotImplementedError

    cdef _unscaled_moment(self, long i):
        raise NotImplementedError

    cpdef long _ord_p(self):
        r"""
        Return power of `p` by which the moments are shifted.

        .. NOTE:

            This is not necessarily the same as the valuation,
            since the moments could all be divisible by `p`.

        EXAMPLES::

            sage: D = OverconvergentDistributions(5, 7, 15)
            sage: v = D([7,14,21,28,35]); v
            (7 + O(7^5), 2*7 + O(7^4), 3*7 + O(7^3), 4*7 + O(7^2), O(7))
            sage: v._ord_p()
            0
        """
        return self.ordp

    def scale(self, left):
        r"""
        Scale the moments of the distribution by ``left``

        INPUT:

        - ``left`` -- scalar

        OUTPUT:

        - Scales the moments by ``left``

        EXAMPLES::

            sage: D = OverconvergentDistributions(5, 7, 15)
            sage: v = D([1,2,3,4,5]); v
            (1 + O(7^5), 2 + O(7^4), 3 + O(7^3), 4 + O(7^2), 5 + O(7))
            sage: v.scale(2)
            (2 + O(7^5), 4 + O(7^4), 6 + O(7^3), 1 + 7 + O(7^2), 3 + O(7))
        """
        # if isinstance(self, Dist_long) and isinstance(left, (Integer, pAdicCappedRelativeElement, pAdicCappedAbsoluteElement, pAdicFixedModElement)):
        #     return self._lmul_(left)
        R = left.parent()
        base = self.parent().base_ring()
        if base is R:
            return self._lmul_(left)
        elif base.has_coerce_map_from(R):
            return self._lmul_(base(left))
        else:
            from sage.categories.pushout import pushout
            new_base = pushout(base, R)
            V = self.parent().change_ring(new_base)
            scalar = new_base(left)
            return V([scalar * new_base(self.moment(i)) for i in range(self.precision_absolute())])

    def is_zero(self, p=None, M=None):
        r"""
        Return True if the `i`-th moment is zero for all `i` (case ``M`` is None)
        or zero modulo `p^{M-i}` for all `i` (when ``M`` is not None).

        Note that some moments are not known to precision ``M``, in which
        case they are only checked to be equal to zero modulo the
        precision to which they are defined.

        INPUT:

        - ``p`` -- prime

        - ``M`` -- precision

        OUTPUT:

        - True/False

        EXAMPLES::

            sage: D = OverconvergentDistributions(5, 7, 15)
            sage: v = D([1,2,3,4,5]); v
            (1 + O(7^5), 2 + O(7^4), 3 + O(7^3), 4 + O(7^2), 5 + O(7))
            sage: v.is_zero()
            False
            sage: v = D(5*[0])
            sage: v.is_zero()
            True

        ::

            sage: D = Symk(0)
            sage: v = D([0])
            sage: v.is_zero(5,3)
            True
        """
        n = self.precision_relative()
        aprec = self.precision_absolute()
        if M is None:
            M = n
        # elif M > aprec: # DEBUG
        #     return False
        elif M < aprec:
            n -= (aprec - M)
            M -= self.ordp
        if p is None:
            p = self.parent().prime()
        cdef bint usearg = True
        if n == 0:
            return True
        else:
            try:
                z = self._unscaled_moment(0).is_zero(M)
            except TypeError:
                z = self._unscaled_moment(0).is_zero()
                use_arg = False
            if not z:
                return False
            for a in xrange(1, n):
                if usearg:
                    try:
                        z = self._unscaled_moment(a).is_zero(M - a)
                    except TypeError:
                        z = self._unscaled_moment(a).is_zero()
                        use_arg = False
                else:
                    z = self._unscaled_moment(a).is_zero()
                if not z:
                    return False
            return True

    def find_scalar(self, _other, p, M=None, check=True):
        r"""
        Return an ``alpha`` with ``other = self * alpha``, or raises
        a ``ValueError``.

        It will also raise a ``ValueError`` if this distribution is zero.

        INPUT:

        - ``other`` -- another distribution

        - ``p`` -- an integral prime (only used if the parent is not a Symk)

        - ``M`` -- (default: None) an integer, the relative precision
          to which the scalar must be determined

        - ``check`` -- (default: True) boolean, whether to validate
          that ``other`` is actually a multiple of this element.

        OUTPUT:

        - A scalar ``alpha`` with ``other = self * alpha``.

        EXAMPLES::

            sage: D = OverconvergentDistributions(5, 7, 15)
            sage: v = D([1,2,3,4,5])
            sage: w = D([3,6,9,12,15])
            sage: v.find_scalar(w,p=7)
            3 + O(7^5)
            sage: v.find_scalar(w,p=7,M=4)
            3 + O(7^4)

            sage: u = D([1,4,9,16,25])
            sage: v.find_scalar(u,p=7)
            Traceback (most recent call last):
            ...
            ValueError: not a scalar multiple
        """
        cdef Dist other = _other
        i = 0
        n = self.precision_relative()
        other_pr = other.precision_relative()
        if n == 0:
            raise ValueError("self is zero")
        verbose("n = %s" % n, level  = 2)
        verbose("moment 0", level = 2)
        a = self._unscaled_moment(i)
        verbose("a = %s" % a, level = 2)
        padic = isinstance(a.parent(), pAdicGeneric)
        if self.parent().is_symk():
            while a == 0:
                if other._unscaled_moment(i) != 0:
                    raise ValueError("not a scalar multiple")
                i += 1
                verbose("moment %s" % i, level = 2)
                try:
                    a = self._unscaled_moment(i)
                except IndexError:
                    raise ValueError("self is zero")
            alpha = other._unscaled_moment(i) / a
            if check:
                i += 1
                while i < n:
                    verbose("comparing moment %s" % i, level = 2)
                    if alpha * self._unscaled_moment(i) != other._unscaled_moment(i):
                        raise ValueError("not a scalar multiple")
                    i += 1
        else:
            p = self.parent().prime()
            v = a.valuation(p)
            while v >= n - i:
                i += 1
                verbose("p moment %s" % i, level = 2)
                try:
                    a = self._unscaled_moment(i)
                except IndexError:
                    raise ValueError("self is zero")
                v = a.valuation(p)
            relprec = n - i - v
#            verbose("p=%s, n-i=%s\nself.moment=%s, other.moment=%s" % (p, n-i, a, other._unscaled_moment(i)),level=2)
## RP: This code was crashing because other may have too few moments -- so I added this bound with other's relative precision
            if padic:
                if i < other_pr:
                    alpha = (other._unscaled_moment(i) / a).add_bigoh(n - i)
                else:
                    alpha = (0 * a).add_bigoh(other_pr - i)
            else:
                if i < other_pr:
                    alpha = (other._unscaled_moment(i) / a) % p ** (n - i)
                else:
                    alpha = 0
            verbose("alpha = %s" % alpha, level = 2)
## RP: This code was crashing because other may have too few moments -- so I added this bound with other's relative precision
            while i < other_pr - 1:
                i += 1
                verbose("comparing p moment %s" % i, level = 2)
                a = self._unscaled_moment(i)
                if check:
#                    verbose("self.moment=%s, other.moment=%s" % (a, other._unscaled_moment(i)))
                    if (padic and other._unscaled_moment(i) != alpha * a) or \
                       (not padic and other._unscaled_moment(i) % p ** (n - i) != alpha * a % p ** (n - i)):
                        raise ValueError("not a scalar multiple")
                v = a.valuation(p)
                if n - i - v > relprec:
                    verbose("Reseting alpha: relprec=%s, n-i=%s, v=%s" % (relprec, n - i, v), level = 2)
                    relprec = n - i - v
                    if padic:
                        alpha = (other._unscaled_moment(i) / a).add_bigoh(n - i)
                    else:
                        alpha = (other._unscaled_moment(i) / a) % p ** (n - i)
                    verbose("alpha=%s" % alpha, level = 2)
            if relprec < M:
                raise ValueError("result not determined to high enough precision")
        alpha = alpha * self.parent().prime() ** (other.ordp - self.ordp)
        verbose("alpha=%s" % alpha, level = 2)
        try:
            alpha = self.parent().base_ring()(alpha)
            if M is not None:
                alpha = alpha.add_bigoh(M)
        except (ValueError, AttributeError):
            pass
        return alpha

    def find_scalar_from_zeroth_moment(self, _other, p, M=None, check=True):
        r"""
        Return an ``alpha`` with ``other = self * alpha`` using only
        the zeroth moment, or raises a ``ValueError``.

        It will also raise a ``ValueError`` if the zeroth moment of the
        distribution is zero.

        INPUT:

        - ``other`` -- another distribution

        - ``p`` -- an integral prime (only used if the parent is not a Symk)

        - ``M`` -- (default: None) an integer, the relative precision
          to which the scalar must be determined

        - ``check`` -- (default: True) boolean, whether to validate
          that ``other`` is actually a multiple of this element.

        OUTPUT:

        - A scalar ``alpha`` with ``other = self * alpha``.

        EXAMPLES::

            sage: D = OverconvergentDistributions(5, 7, 15)
            sage: v = D([1,2,3,4,5])
            sage: w = D([3,6,9,12,15])
            sage: v.find_scalar_from_zeroth_moment(w,p=7)
            3 + O(7^5)
            sage: v.find_scalar_from_zeroth_moment(w,p=7,M=4)
            3 + O(7^4)

            sage: u = D([1,4,9,16,25])
            sage: v.find_scalar_from_zeroth_moment(u,p=7)
            Traceback (most recent call last):
            ...
            ValueError: not a scalar multiple
        """
        cdef Dist other = _other
        n = self.precision_relative()
        other_pr = other.precision_relative()
        if n == 0:
            raise ValueError("zeroth moment is zero")
        verbose("n = %s" % n, level = 2)
        a = self.moment(0)
        if a.is_zero():
            raise ValueError("zeroth moment is zero")
        padic = isinstance(a.parent(), pAdicGeneric)
        alpha = other.moment(0) / a
        if check:
            for i in range(1, n):
                verbose("comparing moment %s" % i, level = 2)
                if alpha * self.moment(i) != other.moment(i):
                    raise ValueError("not a scalar multiple")
        alpha = self.parent().base_ring()(alpha)
        if M is not None:
            try:
                absprec = alpha.precision_absolute()
                if absprec < M:
                    raise ValueError("result not determined to high "
                                     "enough precision")
                verbose("alpha=%s" % (alpha), level = 2)
                alpha = alpha.add_bigoh(M)
            except AttributeError:
                pass
        return alpha

    cpdef int _cmp_(_left, _right) except -2:
        r"""
        Comparison.

        EXAMPLES:

        Equality of two distributions::

            sage: D = OverconvergentDistributions(0, 5, 10)
            sage: D([1, 2]) == D([1])
            True
            sage: D([1]) == D([1, 2])
            True
            sage: v = D([1+O(5^3),2+O(5^2),3+O(5)])
            sage: w = D([1+O(5^2),2+O(5)])
            sage: v == w
            True
            sage: D = Symk(0,Qp(5,5))
            sage: v = 5 * D([4*5^-1+3+O(5^2)])
            sage: w = D([4+3*5+O(5^2)])
            sage: v == w
            True
        """
        cdef Dist left = _left
        cdef Dist right = _right
        left.normalize()
        right.normalize()
        cdef long rprec = min(left._relprec(), right._relprec())
        cdef long i, c
        p = left.parent().prime()
        if left.ordp > right.ordp:
            shift = p ** (left.ordp - right.ordp)
            for i in range(rprec):
                c = cmp(shift * left._unscaled_moment(i), right._unscaled_moment(i))
                if c:
                    return c
        elif left.ordp < right.ordp:
            shift = p ** (right.ordp - left.ordp)
            for i in range(rprec):
                c = cmp(left._unscaled_moment(i), shift * right._unscaled_moment(i))
                if c:
                    return c
        else:
            for i in range(rprec):
                c = cmp(left.moment(i), right.moment(i))
                if c:
                    return c
        return 0

    def diagonal_valuation(self, p=None):
        """
        Return the largest `m` so that this distribution lies in `Fil^m`.

        INPUT:

        - ``p`` -- (default: None) a positive integral prime

        OUTPUT:

        - the largest integer `m` so that `p^m` divides the `0`-th
          moment, `p^{m-1}` divides the first moment, etc.

        EXAMPLES::

            sage: D = OverconvergentDistributions(8, 7, 15)
            sage: v = D([7^(5-i) for i in range(1,5)])
            sage: v
            (O(7^4), O(7^3), O(7^2), O(7))
            sage: v.diagonal_valuation(7)
            4
        """
        if p is None:
            p = self.parent()._p
        n = self.precision_relative()
        return self.ordp + min([n] + [a + self._unscaled_moment(a).valuation(p) for a in range(n)])

    def valuation(self, p=None):
        """
        Return the minimum valuation of any moment.

        INPUT:

        - ``p`` -- (default: None) a positive integral prime

        OUTPUT:

        - an integer

        .. WARNING::

            Since only finitely many moments are computed, this valuation may
            be larger than the actual valuation of this distribution.
            Moreover, this valuation may be smaller than the actual
            valuation if all entries are zero to the known precision.

        EXAMPLES::

            sage: D = OverconvergentDistributions(8, 7, 15)
            sage: v = D([7^(5-i) for i in range(1,5)])
            sage: v
            (O(7^4), O(7^3), O(7^2), O(7))
            sage: v.valuation(7)
            4
        """
        if p is None:
            p = self.parent()._p
        n = self.precision_relative()
        if self.parent().is_symk():
            return self.ordp + min([self._unscaled_moment(a).valuation(p) for a in range(n)])
        else:
            return self.ordp + min([n] + [self._unscaled_moment(a).valuation(p) for a in range(n) if not self._unscaled_moment(a).is_zero()])

    def specialize(self, new_base_ring=None):
        """
        Return the image of this overconvergent distribution under
        the canonical projection from distributions of weight `k` to
        `Sym^k`.

        INPUT:

        - ``new_base_ring`` -- (default: None) a ring giving the
          desired base ring of the result.

        OUTPUT:

        - An element of `Sym^k(K)`, where `K` is the specified base ring.

        EXAMPLES::

            sage: D = OverconvergentDistributions(4, 13)
            sage: d = D([0,2,4,6,8,10,12])
            sage: d.specialize()
            (O(13^7), 2 + O(13^6), 4 + O(13^5), 6 + O(13^4), 8 + O(13^3))
        """
        # self.normalize() # This method should not change self
        k = self.parent()._k
        if k < 0:
            raise ValueError("negative weight")
        if self.precision_absolute() < k + 1:
            raise ValueError("not enough moments")
        V = self.parent().specialize(new_base_ring)
        new_base_ring = V.base_ring()
        if self.precision_relative() == 0:
            return V.zero()
        return V([new_base_ring.coerce(self.moment(j)) for j in range(k + 1)])

    def lift(self, p=None, M=None, new_base_ring=None):
        r"""
        Lift a distribution or element of `Sym^k` to an overconvergent distribution.

        INPUT:

        - ``p`` -- (default: None) a positive integral prime.  If None
          then ``p`` must be available in the parent.

        - ``M`` -- (default: None) a positive integer giving the
          desired number of moments. If None, returns a distribution having one
          more moment than this one.

        - ``new_base_ring`` -- (default: None) a ring giving the desired base
          ring of the result. If None, a base ring is chosen automatically.

        OUTPUT:

        - An overconvergent distribution with `M` moments whose image
          under the specialization map is this element.

        EXAMPLES::

            sage: V = Symk(0)
            sage: x = V(1/4)
            sage: y = x.lift(17, 5)
            sage: y
            (13 + 12*17 + 12*17^2 + 12*17^3 + 12*17^4 + O(17^5), O(17^4), O(17^3), O(17^2), O(17))
            sage: y.specialize()._moments == x._moments
            True
        """
        V = self.parent().lift(p, M, new_base_ring)
        k = V._k
        p = V.prime()
        M = V.precision_cap()
        R = V.base_ring()
        moments = [R(self.moment(j)) for j in range(k + 1)]
        zero = R(0)
        moments.extend([zero] * (M - k - 1))
        mu = V(moments)
        #val = mu.valuation()
        #if val < 0:
        #    # This seems unnatural
        #    print("scaling by ", p, "^", -val, " to keep things integral")
        #    mu *= p**(-val)
        return mu

    def _is_malformed(self):
        r"""
        Check that the precision of ``self`` is sensible.

        EXAMPLE::

            sage: D = sage.modular.pollack_stevens.distributions.Symk(2, base=Qp(5))
            sage: v = D([1, 2, 3])
            sage: v._is_malformed()
            False
            sage: v = D([1 + O(5), 2, 3])
            sage: v._is_malformed()
            True
        """
        n = self.precision_absolute()
        for i in range(n):
            if self.moment(i).precision_absolute() < n - i:
                return True
        return False

    def act_right(self, gamma):
        r"""
        The image of this element under the right action by a
        `2 \times 2` matrix.

        INPUT:

        - ``gamma`` -- the matrix by which to act

        OUTPUT:

        - ``self | gamma``

        .. NOTE::

            You may also just use multiplication ``self * gamma``.

        EXAMPLES::

            sage: D = OverconvergentDistributions(4, 7, 10)
            sage: v = D([98,49,21,28,35])
            sage: M = matrix([[1,0], [7,1]])
            sage: v.act_right(M)
            (2*7^2 + 7^3 + 5*7^4 + O(7^5), 3*7^2 + 6*7^3 + O(7^4), 3*7 + 7^2 + O(7^3), 4*7 + O(7^2), O(7))
        """
        return self.parent()._act(self, gamma)

cdef class Dist_vector(Dist):
    r"""
    A distribution is stored as a vector whose `j`-th entry is the `j`-th moment of the distribution.

    The `j`-th entry is stored modulo `p^{N-j}` where `N` is the total number of moments.
    (This is the accuracy that is maintained after acting by `\Gamma_0(p)`.)

    INPUTS:

    - ``moments`` -- the list of moments.  If ``check == False`` it
      must be a vector in the appropriate approximation module.

    - ``parent`` -- a :class:`distributions.OverconvergentDistributions_class` or
      :class:`distributions.Symk_class` instance

    - ``ordp`` -- an integer.  This MUST be zero in the case of Symk
      of an exact ring.

    - ``check`` -- (default: True) boolean, whether to validate input

    EXAMPLES::

        sage: D = OverconvergentDistributions(3,5,6) # indirect doctest
        sage: v = D([1,1,1])
    """
    def __init__(self, moments, parent, ordp=0, check=True):
        """
        Initialization.

        TESTS::

            sage: Symk(4)(0)
            (0, 0, 0, 0, 0)

        """
        # if not hasattr(parent,'Element'):
        #     parent, moments = moments, parent

        Dist.__init__(self, parent)
        if check:
            # case 1: input is a distribution already
            if isinstance(moments, Dist):
                ordp = moments._ord_p()
                moments = moments._moments.change_ring(parent.base_ring())
            # case 2: input is a vector, or something with a len
            elif hasattr(moments, '__len__'):
                M = len(moments)
                moments = parent.approx_module(M)(moments)
            # case 3: input is zero
            elif moments == 0:
                moments = parent.approx_module(parent.precision_cap())(moments)
            # case 4: everything else
            else:
                moments = parent.approx_module(1)([moments])
            # TODO: This is not quite right if the input is an inexact zero.
            if ordp != 0 and parent.prime() == 0:
                raise ValueError("can not specify a valuation shift for an exact ring")

        self._moments = moments
        self.ordp = ordp
        self.normalize() # DEBUG

    def __reduce__(self):
        r"""
        Used for pickling.

        EXAMPLE::

            sage: D = sage.modular.pollack_stevens.distributions.Symk(2)
            sage: x = D([2,3,4])
            sage: x.__reduce__()
            (<type 'sage.modular.pollack_stevens.dist.Dist_vector'>, ((2, 3, 4), Sym^2 Q^2, 0, False))
        """
        return (self.__class__, (self._moments, self.parent(), self.ordp, False))

    cdef Dist_vector _new_c(self):
        r"""
        Creates an empty distribution.

        Note that you MUST fill in the ordp attribute on the resulting distribution.

        OUTPUT:

        - A distribution with no moments.  The moments are then filled
          in by the calling function.
        """## mm TODO EXAMPLES
        cdef Dist_vector ans = PY_NEW(Dist_vector)
        ans._parent = self._parent
        return ans

    def _repr_(self):
        r"""
        String representation.

        EXAMPLES::

            sage: D = OverconvergentDistributions(5, 7, 15)
            sage: v = D([1,2,3,4,5]); v
            (1 + O(7^5), 2 + O(7^4), 3 + O(7^3), 4 + O(7^2), 5 + O(7))
            sage: repr(v)
            '(1 + O(7^5), 2 + O(7^4), 3 + O(7^3), 4 + O(7^2), 5 + O(7))'
        """
        # self.normalize() # Should normalize only when absolutely needed.
        valstr = ""
        if self.ordp == 1:
            valstr = "%s * " % (self.parent().prime())
        elif self.ordp != 0:
            valstr = "%s^%s * " % (self.parent().prime(), self.ordp)
        if len(self._moments) == 1:
            return valstr + repr(self._moments[0])
        else:
            return valstr + repr(self._moments)

    def _rational_(self):
        """
        Convert to a rational number.

        EXAMPLES::

            sage: D = Symk(0); d = D(4/3); d
            4/3
            sage: QQ(d)
            4/3

        We get a TypeError if there is more than 1 moment::

            sage: D = Symk(1); d = D([1,2]); d
            (1, 2)
            sage: QQ(d)
            Traceback (most recent call last):
            ...
            TypeError: k must be 0
        """
        if len(self._moments) == 1:
            return QQ(self.moment(0))
        raise TypeError("k must be 0")

    cdef long _relprec(self):
        """
        Return the number of moments.
        """ ##mm TODO EXMPLES
        return len(self._moments)

    cdef _unscaled_moment(self, long n):
        r"""
        Return the `n`-th moment, unscaled by the overall power of `p`
        stored in ``self.ordp``.
        """ ##mm TODO EXMPLES
        return self._moments[n]

    cdef Dist_vector _addsub(self, Dist_vector right, bint negate):
        r"""
        Common code for the sum and the difference of two distributions
        """ ##mm TODO
        cdef Dist_vector ans = self._new_c()
        cdef long aprec = min(self.ordp + len(self._moments), right.ordp + len(right._moments))
        ans.ordp = min(self.ordp, right.ordp)
        cdef long rprec = aprec - ans.ordp
        # In the case of symk, rprec will always be k
        V = ans.parent().approx_module(rprec)
        R = V.base_ring()
        smoments = self._moments
        rmoments = right._moments
        # we truncate if the moments are too long; extend by zero if too short
        if smoments.parent() is not V:
            vec = smoments.list(copy=False)[:rprec] + ([R(0)] * (rprec - len(smoments)) if rprec > len(smoments) else [])
            smoments = V(vec)
        if rmoments.parent() is not V:
            vec = rmoments.list(copy=False)[:rprec] + ([R(0)] * (rprec - len(rmoments)) if rprec > len(rmoments) else [])
            rmoments = V(vec)
        # We multiply by the relative power of p
        if self.ordp > right.ordp:
            smoments *= self.parent().prime() ** (self.ordp - right.ordp)
        elif self.ordp < right.ordp:
            rmoments *= self.parent().prime() ** (right.ordp - self.ordp)
        if negate:
            rmoments = -rmoments
        ans._moments = smoments + rmoments
        return ans

    cpdef _add_(self, _right):
        r"""
        Sum of two distributions.

        EXAMPLES::

            sage: D = OverconvergentDistributions(5, 7, 15)
            sage: v = D([1,2,3,4,5]); w = D([3,6,9,12,15])
            sage: v+w
            (4 + O(7^5), 1 + 7 + O(7^4), 5 + 7 + O(7^3), 2 + 2*7 + O(7^2), 6 + O(7))
        """
        return self._addsub(<Dist_vector>_right, False)

    cpdef _sub_(self, _right):
        r"""
        Difference of two distributions.

        EXAMPLES::

            sage: D = OverconvergentDistributions(5, 7, 15)
            sage: v = D([1,2,3,4,5]); w = D([1,1,1,8,8])
            sage: v-w
            (O(7^5), 1 + O(7^4), 2 + O(7^3), 3 + 6*7 + O(7^2), 4 + O(7))
        """
        return self._addsub(<Dist_vector>_right, True)

    cpdef _lmul_(self, RingElement right):
        r"""
        Scalar product of a distribution with a ring element that coerces into the base ring.

        EXAMPLES::

            sage: D = OverconvergentDistributions(5, 7, 15)
            sage: v = D([1,2,3,4,5]); v
            (1 + O(7^5), 2 + O(7^4), 3 + O(7^3), 4 + O(7^2), 5 + O(7))
            sage: 3*v; 7*v
            (3 + O(7^5), 6 + O(7^4), 2 + 7 + O(7^3), 5 + 7 + O(7^2), 1 + O(7))
            7 * (1 + O(7^5), 2 + O(7^4), 3 + O(7^3), 4 + O(7^2), 5 + O(7))
            sage: v*3; v*7
            (3 + O(7^5), 6 + O(7^4), 2 + 7 + O(7^3), 5 + 7 + O(7^2), 1 + O(7))
            7 * (1 + O(7^5), 2 + O(7^4), 3 + O(7^3), 4 + O(7^2), 5 + O(7))
        """
        cdef Dist_vector ans = self._new_c()
        p = self.parent().prime()
        if p == 0:
            ans._moments = self._moments * right
            ans.ordp = self.ordp
        elif right.valuation(p) == Infinity:
            ans._moments = self.parent().approx_module(0)([])
            ans.ordp += self.precision_relative()
        else:
            try:
                v, u = right.val_unit(p)
            except TypeError:  # bug in p-adics: they should accept p here
                v, u = right.val_unit()
            ans._moments = self._moments * u
            ans.ordp = self.ordp + v
            # if the relative precision of u is less than that of self, ans may not be normalized.
        return ans

    def precision_relative(self):
        r"""
        Return the relative precision of this distribution.

        The precision is just the number of moments stored, which is
        also `k+1` in the case of `Sym^k(R)`.  For overconvergent
        distributions, the precision is the integer `m` so that the
        sequence of moments is known modulo `Fil^m`.

        OUTPUT:

        - An integer giving the number of moments.

        EXAMPLES::

            sage: D = OverconvergentDistributions(2, 11, 15)
            sage: v = D([1,1,10,9,6,15])
            sage: v.precision_relative()
            6
            sage: v = v.reduce_precision(4); v.precision_relative()
            4
            sage: D = Symk(10)
            sage: v = D.random_element()
            sage: v.precision_relative()
            11
        """
        return Integer(len(self._moments))

    def precision_absolute(self):
        r"""
        Return the absolute precision of this distribution.

        The absolute precision is the sum of the relative precision
        (number of moments) and the valuation.

        EXAMPLES::

            sage: D = OverconvergentDistributions(3, 7, base = Qp(7))
            sage: v = D([3,1,10,0])
            sage: v.precision_absolute()
            4
            sage: v *= 7
            sage: v.precision_absolute()
            5
            sage: v = 1/7^10 * v
            sage: v.precision_absolute()
            -5
        """
        return Integer(len(self._moments) + self.ordp)

    cpdef normalize(self, include_zeroth_moment = True):
        r"""
        Normalize by reducing modulo `Fil^N`, where `N` is the number of moments.

        If the parent is Symk, then normalize has no effect.  If the
        parent is a space of distributions, then normalize reduces the
        `i`-th moment modulo `p^{N-i}`.

        OUTPUT:

        - this distribtion, after normalizing.

        .. WARNING::

            This function modifies the distribution in place as well as returning it.

        EXAMPLES::

            sage: D = OverconvergentDistributions(3,7,10)
            sage: v = D([1,2,3,4,5]) ; v
            (1 + O(7^5), 2 + O(7^4), 3 + O(7^3), 4 + O(7^2), 5 + O(7))
            sage: w = v.reduce_precision(3) ; w
            (1 + O(7^5), 2 + O(7^4), 3 + O(7^3))
            sage: w.normalize()
            (1 + O(7^3), 2 + O(7^2), 3 + O(7))
            sage: w
            (1 + O(7^3), 2 + O(7^2), 3 + O(7))
            sage: v.reduce_precision(3).normalize(include_zeroth_moment=False)
            (1 + O(7^5), 2 + O(7^2), 3 + O(7))
        """
        if not self.parent().is_symk() and self._moments != 0:  # non-classical
            if len(self._moments) == 0:
                return self
            V = self._moments.parent()
            R = V.base_ring()
            n = self.precision_relative()
            p = self.parent()._p
            shift = self.ordp
            if include_zeroth_moment:
                if isinstance(R, pAdicGeneric):
                    self._moments = V([self._moments[i].add_bigoh(n -shift - i) for i in range(n)])
                else:
                    self._moments = V([self._moments[i] % (p ** (n -shift - i)) for i in range(n)])
            else:
                if isinstance(R, pAdicGeneric):
                    self._moments = V([self._moments[0]] + [self._moments[i].add_bigoh(n -shift - i) for i in range(1, n)])  # Don't normalize the zeroth moment
                else:
                    self._moments = V([self._moments[0]] + [self._moments[i] % (p ** (n -shift- i)) for i in range(1, n)])  # Don't normalize the zeroth moment
        return self

    def reduce_precision(self, M):
        r"""
        Only hold on to `M` moments.

        INPUT:

        - ``M`` -- a positive integer less than the precision of this
          distribution.

        OUTPUT:

        - a new distribution with `M` moments equal to the first `M`
          moments of this distribution.

        EXAMPLES::

            sage: D = OverconvergentDistributions(3,7,10)
            sage: v = D([3,4,5])
            sage: v
            (3 + O(7^3), 4 + O(7^2), 5 + O(7))
            sage: v.reduce_precision(2)
            (3 + O(7^3), 4 + O(7^2))
        """
        assert M <= self.precision_relative(), "not enough moments"

        cdef Dist_vector ans = self._new_c()
        ans._moments = self._moments[:M]
        ans.ordp = self.ordp
        return ans

    def solve_difference_equation(self):
        r"""
        Solve the difference equation. `self = v | \Delta`, where `\Delta = [1, 1; 0, 1] - 1`.

        See Theorem 4.5 and Lemma 4.4 of [PS].

        OUTPUT:

        - a distribution `v` so that `self = v | Delta` , assuming ``self.moment(0) == 0``.
          Otherwise solves the difference equation for ``self - (self.moment(0),0,...,0)``.

        EXAMPLES::

            sage: D = OverconvergentDistributions(5,7,15)
            sage: v = D(([0,2,3,4,5]))
            sage: g = D._act.actor()(Matrix(ZZ,2,2,[1,1,0,1]))
            sage: w = v.solve_difference_equation()
            sage: v - (w*g - w)
            (O(7^4), O(7^3), O(7^2), O(7))
            sage: v = D(([7,2,3,4,5]))
            sage: w = v.solve_difference_equation()
            sage: v - (w*g - w)
            (7 + O(7^4), O(7^3), O(7^2), O(7))
        """
        # assert self._moments[0][0]==0, "not total measure zero"
        # print("result accurate modulo p^",self.moment(0).valuation(self.p) )
        #v=[0 for j in range(0,i)]+[binomial(j,i)*bernoulli(j-i) for j in range(i,M)]
        M = self.precision_relative()
        R = self.parent().base_ring()
        K = R.fraction_field()
        V = self._moments.parent()
        v = [K(0) for i in range(M)]
        bern = [bernoulli(i) for i in range(0, M, 2)]
        minhalf = ~K(-2)
        for m in range(1, M):
            scalar = K(self.moment(m) / m)
            # bernoulli(1) = -1/2; the only nonzero odd bernoulli number
            v[m] += m * minhalf * scalar
            for j in range(m - 1, M, 2):
                v[j] += binomial(j, m - 1) * bern[(j - m + 1) // 2] * scalar
        p = self.parent().prime()
        cdef Dist_vector ans
        if p == 0:
            if R.is_field():
                ans = self._new_c()
                ans.ordp = 0
                ans._moments = V(v)
            else:
                newparent = self.parent().change_ring(K)
                ans = newparent(v)
        else:
            ans = self._new_c()
            try:
                ans.ordp = min(a.valuation(p) for a in v)
            except TypeError:
                ans.ordp = 0
            if ans.ordp < 0:
                scalar = K(p) ** (-ans.ordp)
                ans._moments = V([R(a * scalar) for a in v])
            elif ans.ordp > 0:
                scalar = K(p) ** ans.ordp
                ans._moments = V([R(a // scalar) for a in v])
            else:
                ans._moments = V([R(a) for a in v])
            v = ans._moments
            N = len(ans._moments)
            prec_loss = max([N - j - v[j].precision_absolute()
                             for j in range(N)])
            #            print("precision loss = ", prec_loss)
            if prec_loss > 0:
                ans._moments = ans._moments[:(N - prec_loss)]
        return ans


# cdef class Dist_long(Dist):
#     r"""
#     A class for distributions implemented using a C array of longs.

#     INPUT:

#     - ``moments`` -- the list of moments.  If ``check == False`` it
#       must be a vector in the appropriate approximation module.

#     - ``parent`` -- a :class:`distributions.OverconvergentDistributions_class` or
#       :class:`distributions.Symk_class` instance

#     - ``check`` -- (default: True) boolean, whether to validate input

#     EXAMPLES::

#         sage: from sage.modular.pollack_stevens.distributions import OverconvergentDistributions, Symk
#     """
#     def __init__(self, moments, parent, ordp=0, check=True):
#         """
#         Initialization.

#         TESTS::

#             sage: from sage.modular.pollack_stevens.distributions import OverconvergentDistributions, Symk
#         """
#         # if not hasattr(parent,'Element'):
#         #     parent, moments = moments, parent

#         Dist.__init__(self, parent)
#         p = parent._p
#         cdef int i
#         if check:

#             # case 1: input is a distribution already
#             if isinstance(moments, Dist):
#                 M = len(moments)
#                 moments = [ZZ(moments.moment(i)) for i in range(M)]
#             # case 2: input is a vector, or something with a len
#             elif hasattr(moments, '__len__'):
#                 M = len(moments)
#                 moments = [ZZ(a) for a in parent.approx_module(M)(moments)]
#             # case 3: input is zero
#             elif moments == 0:
#                 M = parent.precision_cap()
#                 moments = [ZZ(0)] * M
#             else:
#                 M = 1
#                 moments = [ZZ(moments)]
#             if M > 100 or 7 * p ** M > ZZ(2) ** (4 * sizeof(long) - 1):  # 6 is so that we don't overflow on gathers
#                 raise ValueError("moments too long")
#         else:
#             M = len(moments)

#         for i in range(len(moments)):
#             self._moments[i] = moments[i]
#         self.relprec = M
#         self.prime_pow = <PowComputer_class?>parent.prime_pow
#         self.normalize()

#     cdef Dist_long _new_c(self):
#         r"""


#         OUTPUT:

#         -

#         EXAMPLES::

#             sage: from sage.modular.pollack_stevens.distributions import OverconvergentDistributions, Symk
#         """
#         cdef Dist_long ans = PY_NEW(Dist_long)
#         ans._parent = self._parent
#         ans.prime_pow = self.prime_pow
#         return ans

#     def _repr_(self):
#         r"""


#         OUTPUT:

#         -

#         EXAMPLES::

#             sage: from sage.modular.pollack_stevens.distributions import OverconvergentDistributions, Symk
#         """
#         valstr = ""
#         if self.ordp == 1:
#             valstr = "%s * " % (self.prime_pow.prime)
#         elif self.ordp != 0:
#             valstr = "%s^%s * " % (self.prime_pow.prime, self.ordp)
#         if self.relprec == 1:
#             return valstr + repr(self._moments[0])
#         else:
#             return valstr + "(" + ", ".join([repr(self._moments[i]) for i in range(self.relprec)]) + ")"

#     cdef int quasi_normalize(self) except -1:
#         r"""


#         OUTPUT:

#         -

#         EXAMPLES::

#             sage: from sage.modular.pollack_stevens.distributions import OverconvergentDistributions, Symk
#         """
#         cdef int i
#         for i in range(self.relprec):
#             if self._moments[i] > overflow:
#                 self._moments[i] = self._moments[i] % self.prime_pow(self.relprec - i)
#             elif self._moments[i] < underflow:
#                 self._moments[i] = self._moments[i] % self.prime_pow(self.relprec - i)
#                 self._moments[i] += self.prime_pow(self.relprec - i)

#     cpdef normalize(self):
#         r"""


#         OUTPUT:

#         -

#         EXAMPLES::

#             sage: from sage.modular.pollack_stevens.distributions import OverconvergentDistributions, Symk
#         """
#         cdef int i
#         for i in range(1, self.relprec):  # Don't normalize the zeroth moment
#             if self._moments[i] < 0:
#                 self._moments[i] = self._moments[i] % self.prime_pow(self.relprec - i)
#                 self._moments[i] += self.prime_pow(self.relprec - i)
#             elif self._moments[i] >= self.prime_pow(self.relprec - i):
#                 self._moments[i] = self._moments[i] % self.prime_pow(self.relprec - i)
#         return self

#     cdef long _relprec(self):
#         return self.relprec

#     cdef _unscaled_moment(self, long _n):
#         r"""


#         INPUT:

#         - ``_n`` -- an integer or slice giving an index into the
#           moments.

#         OUTPUT:

#         -

#         EXAMPLES::

#             sage: from sage.modular.pollack_stevens.distributions import OverconvergentDistributions, Symk
#         """
#         if isinstance(_n, slice):
#             a, b, c = _n.indices(self.relprec)
#             return [self.moment(i) for i in range(a, b, c)]
#         cdef int n = _n
#         if n < 0:
#             n += self.relprec
#         if n < 0 or n >= self.relprec:
#             raise IndexError("list index out of range")
#         return self._moments[n]

#     cdef Dist_long _addsub(self, Dist_long right, bint negate):
#         r"""
#         Common code for the sum and the difference of two distributions
#         """
#         cdef Dist_long ans = self._new_c()
#         cdef long aprec = min(self.ordp + self.relprec, right.ordp + right.relprec)
#         ans.ordp = min(self.ordp, right.ordp)
#         ans.relprec = aprec - ans.ordp
#         # In the case of symk, rprec will always be k
#         cdef int i, n
#         cdef long diff, cutoff
#         # The following COULD overflow, but it would require 2^32
#         # additions (on a 64-bit machine), since we restrict p^k to be
#         # less than 2^31/7.
#         if self.ordp == right.ordp:
#             n = min(self.relprec, right.relprec)
#             for i in range(n):
#                 ans._moments[i] = self._moments[i] - right._moments[i] if negate else self._moments[i] + right._moments[i]
#             if self.relprec < ans.relprec:
#                 for i in range(n, ans.relprec):
#                     ans._moments[i] = -right._moments[i] if negate else right._moments[i]
#             elif ans.relprec < self.relprec:
#                 for i in range(n, ans.relprec):
#                     ans._moments[i] = self._moments[i]
#         elif self.ordp < right.ordp:
#             diff = right.ordp - self.ordp
#             n = min(right.relprec, ans.relprec - diff)
#             for i in range(n):
#                 ans._moments[i] = self.prime_pow(diff) * (right._moments[i] % self.prime_pow(ans.relprec - diff - i))
#                 ans._moments[i] = self._moments[i] - ans._moments[i] if negate else self._moments[i] + ans._moments[i]
#             if n < ans.relprec:
#                 for i in range(n, ans.relprec):
#                     ans._moments[i] = self._moments[i]
#         else:  # self.ordp > right.ordp
#             diff = self.ordp - right.ordp
#             n = min(self.relprec, ans.relprec - diff)
#             for i in range(n):
#                 ans._moments[i] = self.prime_pow(diff) * (self._moments[i] % self.prime_pow(ans.relprec - diff - i))
#                 ans._moments[i] += -right._moments[i] if negate else right._moments[i]
#             if n < ans.relprec:
#                 for i in range(n, ans.relprec):
#                     ans._moments[i] = -right._moments[i] if negate else right._moments[i]
#         return ans

#     cpdef _add_(self, ModuleElement right):
#         r"""


#         EXAMPLES::

#             sage: from sage.modular.pollack_stevens.distributions import OverconvergentDistributions, Symk
#         """
#         return self._addsub(<Dist_long?> right, False)

#     cpdef _sub_(self, ModuleElement right):
#         r"""


#         EXAMPLES::

#             sage: from sage.modular.pollack_stevens.distributions import OverconvergentDistributions, Symk
#         """
#         return self._addsub(<Dist_long?> right, True)

#     cpdef _lmul_(self, RingElement _right):
#         r"""


#         EXAMPLES::

#             sage: from sage.modular.pollack_stevens.distributions import OverconvergentDistributions, Symk
#         """
#         cdef Dist_long ans = self._new_c()
#         ans.relprec = self.relprec
#         self.quasi_normalize()
#         cdef long scalar, absprec, ordp
#         cdef Integer iright, unit, ppow, p = self.prime_pow.prime
#         cdef Rational qright, qunit
#         cdef pAdicCappedAbsoluteElement pcaright
#         cdef pAdicCappedRelativeElement pcrright
#         cdef pAdicFixedModElement pfmright
#         if isinstance(_right, Integer):
#             iright = <Integer>_right
#             if mpz_sgn(iright.value) == 0:
#                 ans.ordp = maxordp
#                 ans.relprec = 0
#                 return ans
#             unit = PY_NEW(Integer)
#             ordp = mpz_remove(unit.value, iright.value, p.value)
#             if mpz_fits_slong_p(unit.value):
#                 scalar = mpz_get_si(iright.value) % self.prime_pow(self.relprec)
#             else:
#                 scalar = mpz_fdiv_ui(iright.value, self.prime_pow(self.relprec))
#         elif isinstance(_right, Rational):
#             qright = <Rational>_right
#             if mpq_sgn(qright.value) == 0:
#                 ans.ordp = maxordp
#                 ans.relprec = 0
#                 return ans
#             qunit = PY_NEW(Rational)
#             ordp = mpz_remove(mpq_numref(qunit.value), mpq_numref(qright.value), p.value)
#             if ordp == 0:
#                 ordp = -mpz_remove(mpq_denref(qunit.value), mpq_denref(qright.value), p.value)
#             else:
#                 mpz_set(mpq_denref(qunit.value), mpq_denref(qright.value))
#             ppow = PY_NEW(Integer)
#             mpz_set_ui(ppow.value, self.prime_pow(self.relprec))
#             # We reuse the pointers inside qunit, since we're going to discard it.
#             mpz_invert(mpq_denref(qunit.value), mpq_denref(qunit.value), ppow.value)
#             mpz_mul(mpq_numref(qunit.value), mpq_numref(qunit.value), mpq_denref(qunit.value))
#             scalar = mpz_fdiv_ui(mpq_numref(qunit.value), self.prime_pow(self.relprec))
#             # qunit should not be used now (it's unnormalized)
#         elif isinstance(_right, pAdicCappedAbsoluteElement):
#             pcaright = <pAdicCappedAbsoluteElement>_right
#             unit = PY_NEW(Integer)
#             ordp = mpz_remove(unit.value, pcaright.value, p.value)
#             if pcaright.absprec - ordp <= self.relprec:
#                 ans.relprec = pcaright.absprec - ordp
#                 scalar = mpz_get_si(unit.value)
#             else:
#                 scalar = mpz_fdiv_ui(unit.value, self.prime_pow(self.relprec))
#         elif isinstance(_right, pAdicCappedRelativeElement):
#             pcrright = <pAdicCappedRelativeElement>_right
#             ordp = pcrright.ordp
#             if pcrright.relprec <= self.relprec:
#                 ans.relprec = pcrright.relprec
#                 scalar = mpz_get_si(pcrright.unit)
#             else:
#                 scalar = mpz_fdiv_ui(pcrright.unit, self.prime_pow(self.relprec))
#         elif isinstance(_right, pAdicFixedModElement):
#             pfmright = <pAdicFixedModElement>_right
#             scalar = mpz_get_si(pfmright.value)
#             ordp = 0
#         cdef int i
#         for i in range(self.relprec):
#             ans._moments[i] = self._moments[i] * scalar
#         ans.ordp = self.ordp + ordp
#         ans.quasi_normalize()
#         return ans

#     def precision_relative(self):
#         return Integer(self.relprec)

#     def precision_absolute(self):
#         r"""


#         OUTPUT:

#         -

#         EXAMPLES::

#             sage: from sage.modular.pollack_stevens.distributions import OverconvergentDistributions, Symk
#         """
#         return Integer(self.relprec + self.ordp)

#     def reduce_precision(self, M):
#         r"""


#         INPUT:

#         - ``M`` -- a positive integer less than the precision of this
#           distribution.

#         OUTPUT:

#         -

#         EXAMPLES::

#             sage: from sage.modular.pollack_stevens.distributions import OverconvergentDistributions, Symk
#         """
#         if M > self.relprec:
#             raise ValueError("not enough moments")
#         if M < 0:
#             raise ValueError("precision must be non-negative")
#         cdef Dist_long ans = self._new_c()
#         ans.relprec = M
#         cdef int i
#         for i in range(ans.relprec):
#             ans._moments[i] = self._moments[i]
#         ans.ordp = self.ordp
#         return ans

#     def solve_diff_eqn(self):
#         r"""


#         OUTPUT:

#         -

#         EXAMPLES::

#             sage: from sage.modular.pollack_stevens.distributions import OverconvergentDistributions, Symk
#         """
#         raise NotImplementedError

#     def __reduce__(self):
#         r"""
#         Used in pickling.

#         EXAMPLE::

#             sage: D = OverconvergentDistributions(0, 5, 10)
#             sage: D([1,2,3,4]).__reduce__()
#             (<type 'sage.modular.pollack_stevens.dist.Dist_long'>, ([1, 2, 3, 4], Space of 5-adic distributions with k=0 action and precision cap 10, 0, False))
#         """
#         return (self.__class__, ([self._moments[i]
#                                   for i in xrange(self.relprec)],
#                                  self.parent(), self.ordp, False))


cdef class WeightKAction(Action):
    r"""
    ## mm TODO

    INPUT:

    - ``Dk`` -- a space of distributions
    - ``character`` -- data specifying a Dirichlet character to apply to
      the top right corner, and a power of the determinant by which to scale.
      See the documentation of
      :class:`sage.modular.pollack_stevens.distributions.OverconvergentDistributions_factory`
      for more details.
    - ``adjuster`` -- a callable object that turns matrices into 4-tuples.
    - ``on_left`` -- whether this action should be on the left.
    - ``dettwist`` -- a power of the determinant to twist by
    - ``padic`` -- if True, define an action of `p`-adic matrices (not just integer ones)

    EXAMPLES::

        sage: D = OverconvergentDistributions(4,5,10,base = Qp(5,20)); D
        Space of 5-adic distributions with k=4 action and precision cap 10
        sage: D._act
        Right action by Monoid Sigma0(5) with coefficients in 5-adic Field with capped relative precision 20 on Space of 5-adic distributions with k=4 action and precision cap 10
    """
    def __init__(self, Dk, character, adjuster, on_left, dettwist, padic=False):
        r"""
        Initialization.

        TESTS::

            sage: D = OverconvergentDistributions(4,5,10,base = Qp(5,20)); D # indirect doctest
            Space of 5-adic distributions with k=4 action and precision cap 10
            sage: D = Symk(10) # indirect doctest
        """
        self._k = Dk._k
#        if self._k < 0: raise ValueError("k must not be negative")
        self._adjuster = adjuster
        self._character = character
        self._dettwist = dettwist
        self._p = Dk._p
        self._symk = Dk.is_symk()
        self._actmat = {}
        self._maxprecs = {}
        if character is None:
            self._Np = ZZ(1)  # all of M2Z acts
        else:
            self._Np = character.modulus()
        if not self._symk:
            self._Np = self._Np.lcm(self._p)

        if padic:
            self._Sigma0 = Sigma0(self._Np, base_ring=Dk.base_ring(), adjuster=self._adjuster)
        else:
            self._Sigma0 = Sigma0(self._Np, base_ring=ZZ, adjuster=self._adjuster)
        Action.__init__(self, self._Sigma0, Dk, on_left, operator.mul)

    def clear_cache(self):
        r"""
        Clear the cached matrices which define the action of `U_p`
        (these depend on the desired precision) and the
        dictionary that stores the maximum precisions computed so far.

        EXAMPLES::

            sage: D = OverconvergentDistributions(4,5,4)
            sage: D([1,2,5,3]) * D._act.actor()(Matrix(ZZ,2,2,[1,1,0,1]))
            (1 + O(5^4), 3 + O(5^3), 2*5 + O(5^2), O(5))
            sage: D._act.clear_cache()
        """
        self._actmat = {}
        self._maxprecs = {}

    cpdef acting_matrix(self, g, M):
        r"""
        The matrix defining the action of ``g`` at precision ``M``.

        INPUT:

        - ``g`` -- an instance of
          :class:`sage.matrix.matrix_generic_dense.Matrix_generic_dense`

        - ``M`` -- a positive integer giving the precision at which
          ``g`` should act.

        OUTPUT:

        - An `M \times M` matrix so that the action of `g` on a
          distribution with `M` moments is given by a vector-matrix
          multiplication.

        .. NOTE::

            This function caches its results.  To clear the cache use
            :meth:`clear_cache`.

        EXAMPLES::

            sage: D = Symk(3)
            sage: v = D([5,2,7,1])
            sage: g = Matrix(ZZ,2,2,[1,3,0,1])
            sage: v * D._act.actor()(g) # indirect doctest
            (5, 17, 64, 253)
        """
        g = g.matrix()
        if not g in self._maxprecs:
            A = self._compute_acting_matrix(g, M)
            self._actmat[g] = {M: A}
            self._maxprecs[g] = M
            return A
        else:
            mats = self._actmat[g]
            if M in mats:
                return mats[M]
            maxprec = self._maxprecs[g]
            if M < maxprec:
                A = mats[maxprec][:M, :M]  # submatrix; might want to reduce precisions
                mats[M] = A
                return A
            if M < 30:  # This should not be hard-coded
                maxprec = max([M, 2 * maxprec])  # This may be wasting memory
            else:
                maxprec = M
            self._maxprecs[g] = maxprec
            mats[maxprec] = self._compute_acting_matrix(g, maxprec)  # could lift from current maxprec
            if M == maxprec:
                return mats[maxprec]
            A = mats[maxprec][:M, :M]  # submatrix; might want to reduce precisions
            mats[M] = A
            return A

    cpdef _compute_acting_matrix(self, g, M):
        r"""
        Compute the matrix defining the action of ``g`` at precision ``M``.

        INPUT:

        - ``g`` -- a `2 \times 2` instance of
          :class:`sage.matrices.matrix_integer_dense.Matrix_integer_dense`

        - ``M`` -- a positive integer giving the precision at which
          ``g`` should act.

        OUTPUT:

        - ``G`` -- an `M \times M` matrix. If `v `is the vector of moments of a
          distribution `\mu`, then `v*G` is the vector of moments of `\mu|[a,b;c,d]`

        EXAMPLES::

            sage: D = Symk(3)
            sage: v = D([5,2,7,1])
            sage: g = Matrix(ZZ,2,2,[-2,1,-1,0])
            sage: v * D._act.actor()(g) # indirect doctest
            (-107, 35, -12, 5)
        """
        raise NotImplementedError


cdef class WeightKAction_vector(WeightKAction):
    cpdef _compute_acting_matrix(self, g, M):
        r"""
        Compute the matrix defining the action of ``g`` at precision ``M``.

        INPUT:

        - ``g`` -- a `2 \times 2` instance of
          :class:`sage.matrix.matrix_generic_dense.Matrix_generic_dense`

        - ``M`` -- a positive integer giving the precision at which
          ``g`` should act.

        OUTPUT:

        - ``G`` -- an `M \times M` matrix. If `v` is the vector of moments of a
          distribution `\mu`, then `v*G` is the vector of moments of `\mu|[a,b;c,d]`

        EXAMPLES::

            sage: D = Symk(3)
            sage: v = D([5,2,7,1])
            sage: g = Matrix(ZZ,2,2,[-2,1,-1,0])
            sage: v * D._act.actor()(g) # indirect doctest
            (-107, 35, -12, 5)
        """
        #tim = verbose("Starting")
        a, b, c, d = self._adjuster(g)
        # if g.parent().base_ring().is_exact():
        #     self._check_mat(a, b, c, d)
        k = self._k
        if g.parent().base_ring() is ZZ:
            if self._symk:
                base_ring = QQ
            else:
                base_ring = Zmod(self._p ** M)
        else:
            base_ring = self.underlying_set().base_ring()
        cdef Matrix B = matrix(base_ring, M, M)
        if M == 0:
            return B.change_ring(self.codomain().base_ring())
        R = PowerSeriesRing(base_ring, 'y', default_prec=M)
        y = R.gen()
        #tim = verbose("Checked, made R",tim)
        # special case for small precision, large weight
        scale = (b + d * y) / (a + c * y)
        t = (a + c * y) ** k  # will already have precision M
        cdef long row, col
        #tim = verbose("Made matrix",tim)
        for col in range(M):
            for row in range(M):
                B.set_unsafe(row, col, t[row])
            t *= scale
        #verbose("Finished loop",tim)
        # the changering here is annoying, but otherwise we have to
        # change ring each time we multiply
        B = B.change_ring(self.codomain().base_ring())
        if self._character is not None:
            B *= self._character(a)
        if self._dettwist is not None:
            B *= (a * d - b * c) ** (self._dettwist)
        return B

    cpdef _call_(self, _v, g):
        r"""
        The right action of ``g`` on a distribution.

        INPUT:

        - ``_v`` -- a :class:`Dist_vector` instance, the distribution
          on which to act.

        - ``g`` -- a `2 \times 2` instance of
          :class:`sage.matrix.matrix_integer_dense.Matrix_integer_dense`.

        OUTPUT:

        - the distribution ``_v * g``.

        EXAMPLES::

            sage: D = sage.modular.pollack_stevens.distributions.Symk(2)
            sage: v = D([2,3,4])
            sage: g = Matrix(ZZ,2,2,[3,-1,1,0])
            sage: v * D._act.actor()(g) # indirect doctest
            (40, -9, 2)

        """
        # if g is a matrix it needs to be immutable
        # hashing on arithmetic_subgroup_elements is by str
        if self.is_left():
            _v, g = g, _v
        if g == 1:
            return _v
        cdef Dist_vector v = <Dist_vector?>_v
        cdef Dist_vector ans = v._new_c()

        try:
            g.set_immutable()
        except AttributeError:
            pass
        coeffmodule = v._moments.parent()
        v_moments = v._moments
        ans._moments = v_moments * self.acting_matrix(g, len(v_moments))
        ans.ordp = v.ordp
        ans.normalize()
        return ans

# cdef inline long mymod(long a, unsigned long pM):
#     """
#     Returns the remainder ``a % pM``.

#     INPUT:

#     - ``a`` -- a long

#     - ``pM`` -- an unsigned long

#     OUPUT:

#     - ``a % pM`` as a positive integer.
#     """
#     a = a % pM
#     if a < 0:
#         a += pM
#     return a


# cdef class SimpleMat(SageObject):
#     r"""
#     A simple class emulating a square matrix that holds its values as
#     a C array of longs.

#     INPUT:

#     - ``M`` -- a positive integer, the dimension of the matrix

#     EXAMPLES::

#         sage: from sage.modular.pollack_stevens.distributions import OverconvergentDistributions, Symk
#     """
#     def __cinit__(self, unsigned long M):
#         r"""
#         Memory initialization.

#         TESTS::

#             sage: from sage.modular.pollack_stevens.distributions import OverconvergentDistributions, Symk
#         """
#         self._inited = False
#         self.M = M
#         self._mat = <long*>sage_malloc(M * M * sizeof(long))
#         if self._mat == NULL:
#             raise MemoryError
#         self._inited = True

#     def __getitem__(self, i):
#         r"""


#         INPUT:

#         - ``i`` -- a tuple containing two slices, each from `0` to `M'` for some `M' < M`

#         OUTPUT:

#         - A new SimpleMat of size `M'` with the top left `M' \times
#           M'` block of values copied over.

#         EXAMPLES::

#             sage: from sage.modular.pollack_stevens.distributions import OverconvergentDistributions, Symk
#         """
#         cdef Py_ssize_t r, c, Mnew, Morig = self.M
#         cdef SimpleMat ans
#         if isinstance(i,tuple) and len(i) == 2:
#             a, b = i
#             if isinstance(a, slice) and isinstance(b, slice):
#                 r0, r1, rs = a.indices(Morig)
#                 c0, c1, cs = b.indices(Morig)
#                 if r0 != 0 or c0 != 0 or rs != 1 or cs != 1:
#                     raise NotImplementedError
#                 Mr = r1
#                 Mc = c1
#                 if Mr != Mc:
#                     raise ValueError("result not square")
#                 Mnew = Mr
#                 if Mnew > Morig:
#                     raise IndexError("index out of range")
#                 ans = SimpleMat(Mnew)
#                 for r in range(Mnew):
#                     for c in range(Mnew):
#                         ans._mat[Mnew * c + r] = self._mat[Morig * c + r]
#                 return ans
#         raise NotImplementedError

#     def __dealloc__(self):
#         r"""
#         Deallocation.

#         TESTS::

#             sage: from sage.modular.pollack_stevens.distributions import OverconvergentDistributions, Symk
#         """
#         sage_free(self._mat)

# cdef class WeightKAction_long(WeightKAction):
#     cpdef _compute_acting_matrix(self, g, _M):
#         r"""


#         INPUT:

#         - ``g`` -- a `2 \times 2` instance of
#           :class:`sage.matrices.matrix_integer_dense.Matrix_integer_dense`

#         - ``_M`` -- a positive integer giving the precision at which
#           ``g`` should act.

#         OUTPUT:

#         - A :class:`SimpleMat` that gives the action of ``g`` at
#           precision ``_M`` in the sense that the moments of the result
#           are obtained from the moments of the input by a
#           vector-matrix multiplication.

#         EXAMPLES::

#             sage: from sage.modular.pollack_stevens.distributions import OverconvergentDistributions, Symk
#         """
#         _a, _b, _c, _d = self._adjuster(g)
#         #if self._character is not None: raise NotImplementedError
#         # self._check_mat(_a, _b, _c, _d)
#         cdef long k = self._k
#         cdef Py_ssize_t row, col, M = _M
#         cdef nmod_poly_t t, scale, xM, bdy
#         cdef mp_limb_t pM = self._p ** M  # unsigned long
#         cdef long a, b, c, d
#         a = mymod(ZZ(_a), pM)
#         b = mymod(ZZ(_b), pM)
#         c = mymod(ZZ(_c), pM)
#         d = mymod(ZZ(_d), pM)
#         cdef mp_limb_t pMinv = 1 / pM  # n_preinvert_limb(pM) # DEBUG!!! was pM
#         nmod_poly_init2_preinv(t, pM, pMinv, M)
#         nmod_poly_init2_preinv(scale, pM, pMinv, M)
#         nmod_poly_init2_preinv(xM, pM, pMinv, M)
#         nmod_poly_init2_preinv(bdy, pM, pMinv, 2)
#         nmod_poly_set_coeff_ui(xM, M, 1)
#         nmod_poly_set_coeff_ui(t, 0, a)
#         nmod_poly_set_coeff_ui(t, 1, c)
#         nmod_poly_inv_series(scale, t, M)
#         nmod_poly_set_coeff_ui(bdy, 0, b)
#         nmod_poly_set_coeff_ui(bdy, 1, d)
#         nmod_poly_mullow(scale, scale, bdy, M)  # scale = (b+dy)/(a+cy)
#         nmod_poly_pow_trunc(t, t, k, M)  # t = (a+cy)^k
#         cdef SimpleMat B = SimpleMat(M)
#         for col in range(M):
#             for row in range(M):
#                 B._mat[M * col + row] = nmod_poly_get_coeff_ui(t, row)
#             if col < M - 1:
#                 nmod_poly_mullow(t, t, scale, M)
#         if self._character is not None:
#             B = B * self._character(_a, _b, _c, _d)
#         return B

#     cpdef _call_(self, _v, g):
#         r"""
#         Application of the action.

#         INPUT:

#         - ``_v`` -- a :class:`Dist_long` instance, the distribution on
#           which to act.

#         - ``g`` -- a `2 \times 2` instance of
#           :class:`sage.matrix.matrix_integer_dense.Matrix_integer_dense`.

#         OUTPUT:

#         - The image of ``_v`` under the action of ``g``.

#         EXAMPLES::

#             sage: from sage.modular.pollack_stevens.distributions import OverconvergentDistributions, Symk
#         """
#         if self.is_left():
#             _v, g = g, _v

#         cdef Dist_long v = <Dist_long?>_v
#         cdef Dist_long ans = v._new_c()
#         ans.relprec = v.relprec
#         ans.ordp = v.ordp
#         cdef long pM = self._p ** ans.relprec
#         cdef SimpleMat B = <SimpleMat>self.acting_matrix(g, ans.relprec)
#         cdef long row, col, entry = 0
#         for col in range(ans.relprec):
#             ans._moments[col] = 0
#             for row in range(ans.relprec):
#                 mom = v._moments[row]
#                 # DEBUG BELOW
#                 # if not mom.parent().base_ring().is_exact():
#                 #     try:
#                 #         mom = mom.apply_map(operator.methodcaller('lift'))
#                 #     except AttributeError:
#                 #         pass
#                 ans._moments[col] += mymod(B._mat[entry] * mom, pM)
#                 entry += 1
#         ans.normalize()
#         return ans