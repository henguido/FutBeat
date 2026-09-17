-- Production cache refresh recorded after securing the country-sync RPC wrappers.
-- Kept as an explicit migration so fresh environments preserve production history.
notify pgrst, 'reload schema';
